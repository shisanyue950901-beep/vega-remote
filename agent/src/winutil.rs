//! Windows 小工具：宽字符串与 SDDL DACL 应用。
//!
//! 只用 windows-sys 的 SECURITY_ATTRIBUTES；SDDL 转换与 SetFileSecurityW 直接按
//! advapi32 的 ABI 声明，避免不同 windows-sys 小版本之间可选参数类型的差异。

#![cfg(windows)]

use std::ffi::c_void;
use std::path::Path;
use std::ptr;

const SDDL_REVISION_1: u32 = 1;
const DACL_SECURITY_INFORMATION: u32 = 0x0000_0004;
const PROTECTED_DACL_SECURITY_INFORMATION: u32 = 0x8000_0000;

#[link(name = "advapi32")]
extern "system" {
    fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
        string_security_descriptor: *const u16,
        string_sd_revision: u32,
        security_descriptor: *mut *mut c_void,
        security_descriptor_size: *mut u32,
    ) -> i32;
    fn SetFileSecurityW(
        file_name: *const u16,
        security_information: u32,
        security_descriptor: *mut c_void,
    ) -> i32;
}

#[link(name = "kernel32")]
extern "system" {
    fn LocalFree(mem: *mut c_void) -> *mut c_void;
}

pub fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

pub fn wide_path(path: &Path) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt;
    path.as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect()
}

/// 把 SDDL 转成安全描述符；调用方在不再需要时用 [`free_descriptor`] 释放。
///
/// 返回裸指针，生命周期由调用方保证；转换失败返回中文错误（不含 SDDL 内容）。
pub fn sddl_descriptor(sddl: &str) -> Result<*mut c_void, String> {
    let text = wide(sddl);
    let mut descriptor: *mut c_void = ptr::null_mut();
    let mut size = 0u32;
    // SAFETY: text 以 NUL 结尾且在调用期间存活；descriptor/size 是有效输出指针。
    let ok = unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            text.as_ptr(),
            SDDL_REVISION_1,
            &mut descriptor,
            &mut size,
        )
    };
    if ok == 0 || descriptor.is_null() {
        return Err("安全描述符转换失败".to_string());
    }
    Ok(descriptor)
}

/// 释放 [`sddl_descriptor`] 返回的本地内存。
pub fn free_descriptor(descriptor: *mut c_void) {
    if !descriptor.is_null() {
        // SAFETY: 指针来自 ConvertStringSecurityDescriptorToSecurityDescriptorW。
        unsafe {
            LocalFree(descriptor);
        }
    }
}

/// 给已存在的文件或目录设置受保护 DACL（SDDL 中的 P 标记同样保留）。
pub fn set_path_dacl(path: &Path, sddl: &str) -> Result<(), String> {
    let descriptor = sddl_descriptor(sddl)?;
    let name = wide_path(path);
    // SAFETY: name 以 NUL 结尾；descriptor 在调用期间有效。
    let ok = unsafe {
        SetFileSecurityW(
            name.as_ptr(),
            DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
            descriptor,
        )
    };
    free_descriptor(descriptor);
    if ok == 0 {
        return Err("设置目录权限失败".to_string());
    }
    Ok(())
}
