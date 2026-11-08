//! Prints a password hash from stdin, propagating I/O and hashing failures.
use std::io::Read;
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input)?;
    let password = input.trim_end_matches(['\n', '\r']);
    if password.is_empty() {
        return Err("A password is required on stdin".into());
    }
    println!("{}", sitepulse_backend::auth::hash_password(password)?);
    Ok(())
}
