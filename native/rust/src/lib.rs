//! Shared mobile API. GraphQL executes inside Rust; no server or JWT is involved.
use std::sync::{
    atomic::{AtomicBool, AtomicI32, AtomicU32, Ordering},
    Arc,
};

use juniper::{http::GraphQLRequest, RootNode};
use rlz::{
    api::coin::{init_datadir, Coin},
    graphql::{mutation::Mutation, query::Query, subs::Subscription, Context},
};
use tokio::sync::{Mutex, OnceCell};

uniffi::setup_scaffolding!();

// rlz's data directory, sync, FROST, and subscription state are process-global.
// Do not pretend independent wallet handles are safe until those are refactored.
static OPENED: AtomicBool = AtomicBool::new(false);
static DATA_DIRECTORY: OnceCell<String> = OnceCell::const_new();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum WalletError {
    #[error("Invalid configuration: {message}")]
    InvalidConfig { message: String },
    #[error("A wallet has already been opened in this process")]
    AlreadyOpen,
    #[error("Wallet operation failed: {message}")]
    Operation { message: String },
}

fn operation(error: impl std::fmt::Display) -> WalletError {
    WalletError::Operation {
        message: error.to_string(),
    }
}

#[derive(uniffi::Record)]
pub struct WalletConfig {
    /// App-owned Application Support/files directory. Fixed for this process.
    pub data_directory: String,
    pub database_name: String,
    /// 0 mainnet, 1 testnet, 2 regtest, 3 ZSA regtest.
    pub network: u8,
    pub server_url: String,
    /// 0 lightwalletd, 1 Zebra JSON-RPC.
    pub server_type: u8,
    pub database_password: Option<String>,
    pub allow_unencrypted_database: bool,
}

impl WalletConfig {
    fn validate(&self) -> Result<(), WalletError> {
        let invalid = |message: &str| WalletError::InvalidConfig {
            message: message.into(),
        };
        if self.network > 3 || self.server_type > 1 {
            return Err(invalid("unsupported network or server type"));
        }
        if !std::path::Path::new(&self.data_directory).is_absolute() {
            return Err(invalid("data_directory must be absolute"));
        }
        let mut components = std::path::Path::new(&self.database_name).components();
        if !matches!(components.next(), Some(std::path::Component::Normal(_)))
            || components.next().is_some()
        {
            return Err(invalid("database_name must be a single filename"));
        }
        if !(self.server_url.starts_with("https://") || self.server_url.starts_with("http://")) {
            return Err(invalid("server_url must use HTTP or HTTPS"));
        }
        match (&self.database_password, self.allow_unencrypted_database) {
            (Some(password), false) if !password.is_empty() => Ok(()),
            (None, true) => Ok(()),
            _ => Err(invalid(
                "supply a nonempty database password or explicitly allow an unencrypted database",
            )),
        }
    }
}

#[derive(uniffi::Record, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountSummary {
    pub id: i32,
    pub name: String,
    pub birth: i32,
    pub height: i32,
    /// Exact decimal ZEC string, never a floating-point currency value.
    pub balance: String,
}

type Schema = RootNode<Query, Mutation, Subscription>;

#[derive(uniffi::Record)]
pub struct CreatedAccount {
    pub account_id: i32,
    /// Returned only for a newly generated seed. Never include this in logs.
    pub mnemonic: Option<String>,
}

#[derive(uniffi::Record)]
pub struct PaymentRequest {
    pub account_id: i32,
    pub address: String,
    /// Decimal ZEC, with at most eight fractional digits.
    pub amount: String,
    pub memo: Option<String>,
    /// Bits: transparent 1, Sapling 2, Orchard 4, Ironwood 8.
    pub source_pools: u8,
    pub deduct_fee: bool,
    pub confirmations: u32,
}

#[derive(Clone, uniffi::Record)]
pub struct PaymentOutput {
    pub address: String,
    pub amount: String,
    pub pool: u8,
}

#[derive(Clone, uniffi::Record)]
pub struct PaymentReview {
    pub account_id: i32,
    pub fee: String,
    /// All real outputs from the fixed proposal, including change.
    pub outputs: Vec<PaymentOutput>,
}

#[derive(uniffi::Record)]
pub struct PaymentReceipt {
    pub txid: String,
    pub warning: Option<String>,
}

#[derive(uniffi::Object)]
pub struct PreparedPayment {
    review: PaymentReview,
    package: Mutex<Option<rlz::api::pay::PcztPackage>>,
    created: std::time::Instant,
}

#[uniffi::export]
impl PreparedPayment {
    pub fn review(&self) -> PaymentReview {
        self.review.clone()
    }
}

fn payment_amount(value: &str) -> Result<u64, WalletError> {
    let invalid = || operation("Enter a positive ZEC amount with at most eight decimal places");
    let (whole, fraction) = value.split_once('.').unwrap_or((value, ""));
    if whole.is_empty()
        || !whole.bytes().all(|b| b.is_ascii_digit())
        || fraction.len() > 8
        || !fraction.bytes().all(|b| b.is_ascii_digit())
    {
        return Err(invalid());
    }
    let whole: u64 = whole.parse().map_err(|_| invalid())?;
    let fractional: u64 = if fraction.is_empty() {
        0
    } else {
        fraction.parse().map_err(|_| invalid())?
    };
    let zats = whole
        .checked_mul(100_000_000)
        .and_then(|n| n.checked_add(fractional * 10_u64.pow(8 - fraction.len() as u32)))
        .ok_or_else(invalid)?;
    if zats == 0 || zats > 2_100_000_000_000_000 {
        return Err(invalid());
    }
    Ok(zats)
}

#[derive(Clone)]
struct SyncSink {
    height: Arc<AtomicU32>,
    error: Arc<std::sync::Mutex<Option<String>>>,
    cancelled: Arc<AtomicBool>,
}

impl rlz::Sink<rlz::api::sync::SyncProgress> for SyncSink {
    async fn send(&self, progress: rlz::api::sync::SyncProgress) {
        self.height.store(progress.height, Ordering::Release);
        if self.cancelled.load(Ordering::Acquire) {
            let _ = rlz::api::sync::cancel_sync().await;
        }
    }
    async fn send_error(&self, error: anyhow::Error) {
        *self.error.lock().unwrap() = Some(error.to_string());
    }
}

#[derive(uniffi::Object)]
pub struct Wallet {
    context: Context,
    schema: Schema,
    // Serialize operations against the shared core; cancel_sync remains independent.
    operations: Mutex<()>,
    syncing_account: AtomicI32,
    sync_height: Arc<AtomicU32>,
    sync_cancelled: Arc<AtomicBool>,
}

#[uniffi::export(async_runtime = "tokio")]
impl Wallet {
    /// Open once per process. Failed opens can be retried with the same data directory.
    #[uniffi::constructor]
    pub async fn open(config: WalletConfig) -> Result<Arc<Self>, WalletError> {
        config.validate()?;
        if OPENED
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Err(WalletError::AlreadyOpen);
        }
        // Release the reservation on error or cancellation, keep it on success.
        struct Reservation(bool);
        impl Drop for Reservation {
            fn drop(&mut self) {
                if !self.0 {
                    OPENED.store(false, Ordering::Release);
                }
            }
        }
        let mut reservation = Reservation(false);
        let _ = rustls::crypto::ring::default_provider().install_default();
        std::fs::create_dir_all(&config.data_directory).map_err(operation)?;
        let directory = std::fs::canonicalize(&config.data_directory)
            .map_err(operation)?
            .to_string_lossy()
            .into_owned();
        let initialized = DATA_DIRECTORY
            .get_or_try_init(|| async {
                init_datadir(&directory).await.map_err(operation)?;
                Ok::<_, WalletError>(directory.clone())
            })
            .await?;
        if initialized != &directory {
            return Err(WalletError::InvalidConfig {
                message: "data_directory cannot change within a process".into(),
            });
        }
        let database = std::path::Path::new(&config.data_directory).join(&config.database_name);
        let coin = Coin::new(Some(config.network))
            .open_database(
                database.to_string_lossy().into_owned(),
                config.database_password,
            )
            .await
            .map_err(operation)?
            .set_lwd(config.server_type, config.server_url)
            .map_err(operation)?;
        let wallet = Arc::new(Self {
            context: Context::new(coin),
            schema: Schema::new(Query {}, Mutation {}, Subscription {}),
            operations: Mutex::new(()),
            syncing_account: AtomicI32::new(0),
            sync_height: Arc::new(AtomicU32::new(0)),
            sync_cancelled: Arc::new(AtomicBool::new(false)),
        });
        reservation.0 = true;
        Ok(wallet)
    }

    /// Standard GraphQL JSON request and response. Resolver errors remain in `errors`.
    /// Queries and mutations only; subscriptions are not driven by this method.
    pub async fn execute(&self, request_json: String) -> Result<String, WalletError> {
        let request: GraphQLRequest = serde_json::from_str(&request_json).map_err(operation)?;
        let _lock = self.operations.lock().await;
        // A fresh loader prevents cached transaction data from surviving mutations.
        let context = Context::new(self.context.coin.clone());
        let response = request.execute(&self.schema, &context).await;
        serde_json::to_string(&response).map_err(operation)
    }

    /// Plan only. Signing and broadcasting require a separate explicit call.
    pub async fn prepare_payment(
        &self,
        request: PaymentRequest,
    ) -> Result<Arc<PreparedPayment>, WalletError> {
        let amount = payment_amount(&request.amount)?;
        if request.account_id <= 0 || request.source_pools == 0 || request.source_pools & !15 != 0 {
            return Err(operation(
                "Select an account and at least one valid source pool",
            ));
        }
        if request.memo.as_ref().is_some_and(|memo| memo.len() > 512) {
            return Err(operation("Memo exceeds 512 UTF-8 bytes"));
        }
        if request.address.trim().is_empty() {
            return Err(operation("Enter a recipient address"));
        }
        let _lock = self.operations.lock().await;
        let mut coin = self.context.coin.clone();
        coin.account = request.account_id as u32;
        let recipient = rlz::pay::Recipient {
            address: request.address.trim().into(),
            amount,
            user_memo: request.memo,
            ..Default::default()
        };
        let package = rlz::api::pay::prepare_software_payment(
            recipient,
            request.source_pools,
            request.deduct_fee,
            request.confirmations,
            &coin,
        )
        .await
        .map_err(operation)?;
        let plan = rlz::api::pay::to_plan(&package, &coin).map_err(operation)?;
        if !plan.can_sign {
            return Err(operation("This account cannot sign this payment"));
        }
        let review = PaymentReview {
            account_id: request.account_id,
            fee: rlz::pay::prepare::to_zec(plan.fee),
            outputs: plan
                .outputs
                .into_iter()
                .map(|output| PaymentOutput {
                    address: output.address,
                    amount: rlz::pay::prepare::to_zec(output.amount),
                    pool: output.pool,
                })
                .collect(),
        };
        Ok(Arc::new(PreparedPayment {
            review,
            package: Mutex::new(Some(package)),
            created: std::time::Instant::now(),
        }))
    }

    /// Consume the exact reviewed proposal once; never silently re-plan or retry a payment.
    pub async fn submit_payment(
        &self,
        payment: Arc<PreparedPayment>,
    ) -> Result<PaymentReceipt, WalletError> {
        let _lock = self.operations.lock().await;
        let mut slot = payment.package.lock().await;
        let package = slot
            .take()
            .ok_or_else(|| operation("Payment proposal has already been consumed"))?;
        if payment.created.elapsed() > std::time::Duration::from_secs(300) {
            return Err(operation("Payment review expired. Prepare a new payment"));
        }
        let mut coin = self.context.coin.clone();
        coin.account = payment.review.account_id as u32;
        let (txid, warning) = rlz::api::pay::submit_software_payment(&package, &coin)
            .await
            .map_err(operation)?;
        Ok(PaymentReceipt { txid, warning })
    }

    pub async fn spendable_pools(
        &self,
        account_id: i32,
        height: u32,
        confirmations: u32,
    ) -> Result<Vec<String>, WalletError> {
        if account_id <= 0 {
            return Err(operation("Select an account"));
        }
        let _lock = self.operations.lock().await;
        let mut coin = self.context.coin.clone();
        coin.account = account_id as u32;
        let balances = rlz::api::pay::spendable_pools(height, confirmations, &coin)
            .await
            .map_err(operation)?;
        Ok(balances
            .into_iter()
            .map(rlz::pay::prepare::to_zec)
            .collect())
    }

    pub async fn accounts(&self) -> Result<Vec<AccountSummary>, WalletError> {
        let json = self
            .execute(r#"{"query":"{ accounts { id name birth height balance } }"}"#.into())
            .await?;
        let response: serde_json::Value = serde_json::from_str(&json).map_err(operation)?;
        if let Some(errors) = response.get("errors") {
            return Err(operation(errors));
        }
        serde_json::from_value(response["data"]["accounts"].clone()).map_err(operation)
    }

    pub async fn synchronize_account(&self, account_id: i32) -> Result<i32, WalletError> {
        if account_id <= 0 {
            return Err(WalletError::InvalidConfig {
                message: "account_id must be positive".into(),
            });
        }
        let _lock = self.operations.lock().await;
        self.sync_cancelled.store(false, Ordering::Release);
        let height = self.account_sync_height(account_id).await?;
        self.sync_height.store(height, Ordering::Release);
        self.syncing_account.store(account_id, Ordering::Release);
        struct ActiveSync<'a>(&'a AtomicI32);
        impl Drop for ActiveSync<'_> {
            fn drop(&mut self) {
                self.0.store(0, Ordering::Release);
            }
        }
        let _active = ActiveSync(&self.syncing_account);
        let tip = self.chain_tip().await?;
        if self.sync_cancelled.load(Ordering::Acquire) {
            return Err(operation("Sync canceled"));
        }
        let sink = SyncSink {
            height: Arc::clone(&self.sync_height),
            error: Arc::new(std::sync::Mutex::new(None)),
            cancelled: Arc::clone(&self.sync_cancelled),
        };
        // The core reports scan failures to Sink even when it returns Ok(tip).
        // Preserve those failures at the native boundary instead of claiming success.
        rlz::sync::synchronize_impl(
            sink.clone(),
            vec![account_id as u32],
            tip,
            100_000,
            rlz::sync::DEFAULT_TRANSPARENT_LIMIT,
            10_000,
            false,
            &self.context.coin,
        )
        .await
        .map_err(operation)?;
        if let Some(error) = sink.error.lock().unwrap().take() {
            return Err(operation(error));
        }
        let stored = self.account_sync_height(account_id).await?;
        if stored < tip {
            return Err(operation(
                "Synchronization stopped before reaching the chain tip",
            ));
        }
        i32::try_from(stored).map_err(operation)
    }

    /// Live scanning height. It is not a confirmation of committed wallet state.
    pub fn sync_progress_height(&self, account_id: i32) -> Option<u32> {
        (self.syncing_account.load(Ordering::Acquire) == account_id && account_id > 0)
            .then(|| self.sync_height.load(Ordering::Acquire))
    }

    /// Read independently of the operation lock so status can update during sync.
    pub async fn account_sync_height(&self, account_id: i32) -> Result<u32, WalletError> {
        if account_id <= 0 {
            return Err(operation("account_id must be positive"));
        }
        let mut coin = self.context.coin.clone();
        coin.account = account_id as u32;
        Ok(rlz::api::sync::get_db_height(&coin)
            .await
            .map_err(operation)?
            .height)
    }

    pub async fn chain_tip(&self) -> Result<u32, WalletError> {
        tokio::time::timeout(
            std::time::Duration::from_secs(15),
            rlz::api::network::get_current_height(&self.context.coin),
        )
        .await
        .map_err(operation)?
        .map_err(operation)
    }

    /// An absent or empty key creates a new 24-word seed; a provided key imports it.
    /// A missing birthday uses the current server height.
    pub async fn create_account(
        &self,
        name: String,
        key: Option<String>,
        birth: Option<u32>,
    ) -> Result<CreatedAccount, WalletError> {
        let name = name.trim().to_string();
        if name.is_empty() {
            return Err(operation("Account name is required"));
        }
        let _lock = self.operations.lock().await;
        let key = key.filter(|value| !value.trim().is_empty());
        let generated = key.is_none();
        let key = match key {
            Some(key) => key.trim().to_string(),
            None => rlz::api::key::generate_seed().map_err(operation)?,
        };
        let birthday = match birth {
            Some(birth) => birth,
            None => self.chain_tip().await?,
        };
        let account_id = rlz::api::account::new_account(
            &rlz::api::account::NewAccount {
                icon: None,
                name,
                restore: !generated,
                key: key.clone(),
                passphrase: None,
                fingerprint: None,
                aindex: 0,
                birth: Some(birthday),
                folder: String::new(),
                pools: None,
                use_internal: false,
                internal: false,
                hw: 0,
            },
            &self.context.coin,
        )
        .await
        .map_err(operation)?;
        Ok(CreatedAccount {
            account_id: account_id as i32,
            mnemonic: generated.then_some(key),
        })
    }

    /// Explicit recovery action, including after an interrupted initial backup.
    pub async fn recovery_phrase(&self, account_id: i32) -> Result<Option<String>, WalletError> {
        if account_id <= 0 {
            return Err(operation("account_id must be positive"));
        }
        let _lock = self.operations.lock().await;
        let mut coin = self.context.coin.clone();
        coin.account = account_id as u32;
        Ok(
            rlz::api::account::get_account_seed(account_id as u32, &coin)
                .await
                .map_err(operation)?
                .map(|seed| seed.mnemonic),
        )
    }

    pub async fn cancel_sync(&self) -> Result<(), WalletError> {
        self.sync_cancelled.store(true, Ordering::Release);
        rlz::api::sync::cancel_sync().await.map_err(operation)
    }

    pub fn sapling_params_available(&self) -> bool {
        rlz::api::sapling::check_sapling_params().downloaded
    }

    /// Explicit opt-in to the ~50 MB download; opening a wallet never downloads it.
    pub async fn download_sapling_params(&self) -> Result<(), WalletError> {
        let _lock = self.operations.lock().await;
        rlz::api::sapling::download_sapling_params()
            .await
            .map_err(operation)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn sync_sink_retains_scan_height_and_error() {
        let sink = SyncSink {
            height: Arc::new(AtomicU32::new(0)),
            error: Arc::new(std::sync::Mutex::new(None)),
            cancelled: Arc::new(AtomicBool::new(false)),
        };
        rlz::Sink::send(
            &sink,
            rlz::api::sync::SyncProgress {
                height: 123,
                time: 0,
            },
        )
        .await;
        assert_eq!(sink.height.load(Ordering::Acquire), 123);
        rlz::Sink::<rlz::api::sync::SyncProgress>::send_error(
            &sink,
            anyhow::anyhow!("scan failed"),
        )
        .await;
        assert_eq!(sink.error.lock().unwrap().as_deref(), Some("scan failed"));
    }

    #[test]
    fn payment_amount_is_exact_and_rejects_unsafe_values() {
        assert_eq!(payment_amount("0.00000001").unwrap(), 1);
        assert_eq!(payment_amount("3.14012345").unwrap(), 314_012_345);
        assert_eq!(payment_amount("21000000").unwrap(), 2_100_000_000_000_000);
        for invalid in [
            "",
            "0",
            "-1",
            "+1",
            "1e8",
            "0.000000001",
            "21000000.00000001",
            "18446744073709551615",
            "NaN",
            "1.2.3",
        ] {
            assert!(payment_amount(invalid).is_err(), "accepted {invalid}");
        }
    }

    #[tokio::test]
    async fn encrypted_wallet_and_in_process_graphql() {
        let directory = tempfile::tempdir().unwrap();
        let config = || WalletConfig {
            data_directory: directory.path().to_string_lossy().into_owned(),
            database_name: "wallet.db".into(),
            network: 2,
            server_url: "http://127.0.0.1:1".into(),
            server_type: 0,
            database_password: Some("test-only-password".into()),
            allow_unencrypted_database: false,
        };
        let mut invalid = config();
        invalid.database_name = "../escape.db".into();
        assert!(matches!(
            Wallet::open(invalid).await,
            Err(WalletError::InvalidConfig { .. })
        ));
        let mut invalid = config();
        invalid.database_password = None;
        assert!(matches!(
            Wallet::open(invalid).await,
            Err(WalletError::InvalidConfig { .. })
        ));
        let mut corrupt = config();
        corrupt.database_name = "corrupt.db".into();
        std::fs::write(directory.path().join("corrupt.db"), [0xAB; 4096]).unwrap();
        assert!(matches!(
            Wallet::open(corrupt).await,
            Err(WalletError::Operation { .. })
        ));
        let other_directory = tempfile::tempdir().unwrap();
        let mut changed_directory = config();
        changed_directory.data_directory = other_directory.path().to_string_lossy().into_owned();
        assert!(matches!(
            Wallet::open(changed_directory).await,
            Err(WalletError::InvalidConfig { .. })
        ));
        let wallet = Wallet::open(config()).await.unwrap();
        let pending = Arc::new(PreparedPayment {
            review: PaymentReview {
                account_id: 1,
                fee: "0".into(),
                outputs: vec![],
            },
            package: Mutex::new(Some(rlz::api::pay::PcztPackage {
                pczt: vec![],
                n_spends: [0; 4],
                sapling_indices: vec![],
                orchard_indices: vec![],
                ironwood_indices: vec![],
                can_sign: true,
                can_broadcast: true,
                price: None,
                category: None,
                is_issuance: false,
            })),
            created: std::time::Instant::now() - std::time::Duration::from_secs(301),
        });
        assert!(wallet
            .submit_payment(pending.clone())
            .await
            .err()
            .unwrap()
            .to_string()
            .contains("expired"));
        assert!(wallet
            .submit_payment(pending)
            .await
            .err()
            .unwrap()
            .to_string()
            .contains("consumed"));
        assert!(wallet.accounts().await.unwrap().is_empty());
        let account_id = rlz::api::account::new_account(
            &rlz::api::account::NewAccount {
                icon: None, name: "Smoke account".into(), restore: true,
                key: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about".into(),
                passphrase: None, fingerprint: None, aindex: 0, birth: Some(1),
                folder: String::new(), pools: None, use_internal: false, internal: false, hw: 0,
            }, &wallet.context.coin
        ).await.unwrap();
        let accounts = wallet.accounts().await.unwrap();
        assert_eq!(accounts.len(), 1);
        assert_eq!(accounts[0].id, account_id as i32);
        assert_eq!(accounts[0].name, "Smoke account");
        assert_eq!(accounts[0].balance.parse::<f64>().unwrap(), 0.0);
        let response = wallet.execute(serde_json::json!({
            "query": "mutation Rename($id: Int!) { editAccount(idAccount: $id, updateAccount: {name: \"Renamed\"}) }",
            "variables": { "id": account_id }
        }).to_string()).await.unwrap();
        assert!(serde_json::from_str::<serde_json::Value>(&response)
            .unwrap()
            .get("errors")
            .is_none());
        assert_eq!(wallet.accounts().await.unwrap()[0].name, "Renamed");
        let fresh = wallet
            .create_account("Fresh wallet".into(), Some(String::new()), Some(1))
            .await
            .unwrap();
        let phrase = fresh.mnemonic.unwrap();
        assert_eq!(phrase.split_whitespace().count(), 24);
        assert!(rlz::api::key::is_valid_phrase(&phrase));
        assert_eq!(
            wallet.recovery_phrase(fresh.account_id).await.unwrap(),
            Some(phrase)
        );
        assert_eq!(wallet.accounts().await.unwrap().len(), 2);
        assert!(wallet.account_sync_height(fresh.account_id).await.unwrap() <= 1);
        assert_eq!(wallet.sync_progress_height(fresh.account_id), None);
        let dashboard = wallet.execute(serde_json::json!({
            "query": "query Dashboard($id: Int!) { balance: balanceByAccount(idAccount: $id) { height transparent sapling orchard ironwood total } address: addressByAccount(idAccount: $id) { ua transparent sapling orchard } transactions: transactionsByAccount(idAccount: $id) { id txid height time value } }",
            "variables": {"id": fresh.account_id}
        }).to_string()).await.unwrap();
        let dashboard: serde_json::Value = serde_json::from_str(&dashboard).unwrap();
        assert!(dashboard.get("errors").is_none(), "{dashboard}");
        assert!(dashboard["data"]["balance"]["total"].is_string());
        assert!(dashboard["data"]["address"]["ua"].is_string());
        assert_eq!(
            dashboard["data"]["transactions"].as_array().unwrap().len(),
            0
        );
        let response = wallet
            .execute(r#"{"query":"query Version { apiVersion }","operationName":"Version"}"#.into())
            .await
            .unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&response).unwrap()["data"]["apiVersion"],
            "1.0"
        );
        let response = wallet
            .execute(r#"{"query":"{ missingField }"}"#.into())
            .await
            .unwrap();
        assert!(serde_json::from_str::<serde_json::Value>(&response)
            .unwrap()
            .get("errors")
            .is_some());
        assert!(wallet.execute("invalid JSON".into()).await.is_err());
        assert!(matches!(
            Wallet::open(config()).await,
            Err(WalletError::AlreadyOpen)
        ));
        let bytes = std::fs::read(directory.path().join("wallet.db")).unwrap();
        assert!(!bytes.starts_with(b"SQLite format 3"));
    }
}
