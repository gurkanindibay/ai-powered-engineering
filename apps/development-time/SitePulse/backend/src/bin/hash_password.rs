//! Prints the argon2id PHC hash of a password read from stdin.
//!
//! Usage: `echo -n 'secret' | cargo run --bin hash-password`
use std::io::Read;

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).expect("read stdin");
    let password = input.trim_end_matches(['\n', '\r']);
    if password.is_empty() {
        eprintln!("usage: echo -n '<password>' | hash-password");
        std::process::exit(2);
    }
    println!("{}", sitepulse_backend::auth::hash_password(password));
}
