//! API keys live only in Windows Credential Manager, never in the settings file
//! (the macOS app keeps them in the Keychain for the same reason).

use windows_sys::Win32::Security::Credentials::{
    CredDeleteW, CredFree, CredReadW, CredWriteW, CREDENTIALW, CRED_PERSIST_LOCAL_MACHINE, CRED_TYPE_GENERIC,
};

/// Same prefix as the macOS Keychain service name, followed by the account.
const TARGET_PREFIX: &str = "io.github.mori-ri.hibivo.api-keys/";
const ACCOUNTS: [&str; 4] = ["soniox", "anthropic", "openai-compatible", "gemini"];

fn target(account: &str) -> Result<Vec<u16>, String> {
    if !ACCOUNTS.contains(&account) {
        return Err(format!("unknown account {account}"));
    }
    Ok(format!("{TARGET_PREFIX}{account}").encode_utf16().chain([0]).collect())
}

#[tauri::command]
pub fn secret_get(account: String) -> Result<Option<String>, String> {
    let target = target(&account)?;
    unsafe {
        let mut credential: *mut CREDENTIALW = std::ptr::null_mut();
        if CredReadW(target.as_ptr(), CRED_TYPE_GENERIC, 0, &mut credential) == 0 {
            return Ok(None); // Not saved (ERROR_NOT_FOUND) or unreadable: either way there is no key.
        }
        let blob = std::slice::from_raw_parts((*credential).CredentialBlob, (*credential).CredentialBlobSize as usize);
        let value = String::from_utf8(blob.to_vec()).ok();
        CredFree(credential as *const _);
        Ok(value)
    }
}

/// Saves the key, or deletes it when `value` is empty.
#[tauri::command]
pub fn secret_set(account: String, value: String) -> Result<(), String> {
    let target = target(&account)?;
    let value = value.trim();
    unsafe {
        if value.is_empty() {
            CredDeleteW(target.as_ptr(), CRED_TYPE_GENERIC, 0);
            return Ok(());
        }
        let user: Vec<u16> = "HibiVo".encode_utf16().chain([0]).collect();
        let mut blob = value.as_bytes().to_vec();
        let mut credential: CREDENTIALW = std::mem::zeroed();
        credential.Type = CRED_TYPE_GENERIC;
        credential.TargetName = target.as_ptr() as *mut u16;
        credential.UserName = user.as_ptr() as *mut u16;
        credential.CredentialBlobSize = blob.len() as u32;
        credential.CredentialBlob = blob.as_mut_ptr();
        credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
        if CredWriteW(&credential, 0) == 0 {
            return Err("資格情報マネージャーに保存できませんでした".into());
        }
    }
    Ok(())
}
