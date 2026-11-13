/// 移动端系统根证书字节。读不到返回空，不 panic、不返回 Err。
/// 桌面走 rustls-native-certs，这里返回空以免重复加载。
pub(crate) fn load() -> Vec<Vec<u8>> {
    load_impl()
}

#[cfg(target_os = "ios")]
fn load_impl() -> Vec<Vec<u8>> {
    use core_foundation::array::CFArray;
    use core_foundation::base::TCFType;
    use security_framework::certificate::SecCertificate;
    use std::ffi::{c_char, c_void};
    use std::ptr;

    type CopyAnchors = unsafe extern "C" fn(*mut core_foundation::array::CFArrayRef) -> i32;

    unsafe extern "C" {
        fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
    }
    // Darwin RTLD_DEFAULT
    const RTLD_DEFAULT: *mut c_void = -2isize as *mut c_void;

    unsafe {
        // 该符号在 iOS SDK 标为 IPHONE_NA、不在 Security.tbd；硬链会失败，运行时探测。
        let sym = dlsym(RTLD_DEFAULT, c"SecTrustCopyAnchorCertificates".as_ptr());
        if sym.is_null() {
            return Vec::new();
        }
        let copy_anchors: CopyAnchors = std::mem::transmute(sym);
        let mut array = ptr::null();
        if copy_anchors(&mut array) != 0 || array.is_null() {
            return Vec::new();
        }
        let array = CFArray::<SecCertificate>::wrap_under_create_rule(array);
        array
            .into_iter()
            .filter_map(|c| {
                let der = c.to_der();
                (!der.is_empty()).then_some(der)
            })
            .collect()
    }
}

#[cfg(target_os = "android")]
fn load_impl() -> Vec<Vec<u8>> {
    const DIRS: &[&str] = &[
        "/system/etc/security/cacerts",
        "/apex/com.android.conscrypt/cacerts",
        "/data/misc/user/0/cacerts-added",
    ];
    let mut out = Vec::new();
    for dir in DIRS {
        let Ok(entries) = std::fs::read_dir(dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_file() {
                continue;
            }
            if let Ok(bytes) = std::fs::read(path) {
                if !bytes.is_empty() {
                    out.push(bytes);
                }
            }
        }
    }
    out
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn load_impl() -> Vec<Vec<u8>> {
    Vec::new()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn load_never_panics() {
        let _ = load();
    }

    #[cfg(not(any(target_os = "ios", target_os = "android")))]
    #[test]
    fn desktop_returns_empty() {
        assert!(load().is_empty());
    }
}
