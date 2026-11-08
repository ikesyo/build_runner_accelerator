//! Windows creation of compile-only configuration files.
use std::ffi::c_void;
use std::fs::File;
use std::io;
use std::os::windows::{ffi::OsStrExt, io::FromRawHandle};
use std::path::Path;
use std::ptr;

#[repr(C)]
struct SecurityAttributes {
    length: u32,
    descriptor: *mut c_void,
    inherit_handle: i32,
}

#[link(name = "advapi32")]
unsafe extern "system" {
    fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
        text: *const u16,
        revision: u32,
        descriptor: *mut *mut c_void,
        size: *mut u32,
    ) -> i32;
}

#[link(name = "kernel32")]
unsafe extern "system" {
    fn LocalFree(memory: *mut c_void) -> *mut c_void;
    fn CreateFileW(
        name: *const u16,
        access: u32,
        sharing: u32,
        attributes: *const SecurityAttributes,
        creation: u32,
        flags: u32,
        template: *mut c_void,
    ) -> *mut c_void;
}

struct LocalAllocation(*mut c_void);
impl Drop for LocalAllocation {
    fn drop(&mut self) {
        // SAFETY: these allocations come from Windows APIs requiring LocalFree.
        unsafe { LocalFree(self.0) };
    }
}

pub(super) fn create_compiler_config(path: &Path) -> io::Result<File> {
    // Canonicalize the existing parent to obtain a verbatim Windows path, also
    // supporting long paths. The new leaf must remain exclusively created.
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::other("missing config parent"))?;
    let name = path
        .file_name()
        .ok_or_else(|| io::Error::other("missing config name"))?;
    let path = std::fs::canonicalize(parent)?.join(name);
    let name: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
    if name[..name.len() - 1].contains(&0) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "NUL in config path",
        ));
    }
    // Protected DACL: no inherited grants; only the object's owner has access.
    // OW is OWNER RIGHTS, not the inheritance-only CREATOR OWNER placeholder.
    let sddl: Vec<u16> = "D:P(A;;FA;;;OW)\0".encode_utf16().collect();
    let mut descriptor = ptr::null_mut();
    // SAFETY: the string is NUL-terminated and output pointers are valid.
    if unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl.as_ptr(),
            1,
            &mut descriptor,
            ptr::null_mut(),
        )
    } == 0
    {
        return Err(io::Error::last_os_error());
    }
    let descriptor = LocalAllocation(descriptor);
    let attributes = SecurityAttributes {
        length: size_of::<SecurityAttributes>() as u32,
        descriptor: descriptor.0,
        inherit_handle: 0,
    };
    // SAFETY: path/attributes remain valid for the call. CREATE_NEW (1)
    // preserves exclusive creation; the returned handle is owned by File.
    let handle = unsafe {
        CreateFileW(
            name.as_ptr(),
            0x40000000,
            1,
            &attributes,
            1,
            0x80,
            ptr::null_mut(),
        )
    };
    if handle == -1isize as *mut c_void {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: CreateFileW returned a new valid, uniquely owned handle.
    Ok(unsafe { File::from_raw_handle(handle) })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[link(name = "advapi32")]
    unsafe extern "system" {
        fn GetNamedSecurityInfoW(
            name: *const u16,
            kind: u32,
            information: u32,
            owner: *mut *mut c_void,
            group: *mut *mut c_void,
            dacl: *mut *mut c_void,
            sacl: *mut *mut c_void,
            descriptor: *mut *mut c_void,
        ) -> u32;
        fn ConvertSecurityDescriptorToStringSecurityDescriptorW(
            descriptor: *const c_void,
            revision: u32,
            information: u32,
            text: *mut *mut u16,
            length: *mut u32,
        ) -> i32;
    }

    #[test]
    fn compiler_config_has_protected_owner_acl_and_exclusive_creation() {
        let root = std::env::temp_dir().join(format!("aot-acl-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let path = root.join("config.json");
        let mut file = create_compiler_config(&path).unwrap();
        file.write_all(b"private config").unwrap();
        drop(file);
        assert_eq!(
            create_compiler_config(&path).unwrap_err().kind(),
            io::ErrorKind::AlreadyExists
        );
        assert_eq!(std::fs::read(&path).unwrap(), b"private config");
        let name: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
        let mut descriptor = ptr::null_mut();
        // SAFETY: the path and all output pointers are valid. SE_FILE_OBJECT=1,
        // DACL_SECURITY_INFORMATION=4; Windows allocates the descriptor.
        assert_eq!(
            unsafe {
                GetNamedSecurityInfoW(
                    name.as_ptr(),
                    1,
                    4,
                    ptr::null_mut(),
                    ptr::null_mut(),
                    ptr::null_mut(),
                    ptr::null_mut(),
                    &mut descriptor,
                )
            },
            0
        );
        let descriptor = LocalAllocation(descriptor);
        let mut text = ptr::null_mut();
        let mut length = 0;
        // SAFETY: the descriptor is valid and Windows allocates the string.
        assert_ne!(
            unsafe {
                ConvertSecurityDescriptorToStringSecurityDescriptorW(
                    descriptor.0,
                    1,
                    4,
                    &mut text,
                    &mut length,
                )
            },
            0
        );
        let allocation = LocalAllocation(text.cast());
        // SAFETY: the returned length includes the trailing NUL.
        let sddl = unsafe { std::slice::from_raw_parts(text, length as usize - 1) };
        assert_eq!(String::from_utf16(sddl).unwrap(), "D:P(A;;FA;;;OW)");
        drop(allocation);
        std::fs::remove_dir_all(root).unwrap();
    }
}
