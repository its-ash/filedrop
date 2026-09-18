//! Device pairing: token generation, QR payload, and the pairing state
//! machine that gates transfers between two devices that have not paired
//! before.

mod qr;
mod state;
mod token;

pub use qr::QrPairingPayload;
pub use state::{PairingRequest, PairingState, PairingStateMachine};
pub use token::generate_pairing_token;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_tokens_are_unique_and_well_formed() {
        let a = generate_pairing_token();
        let b = generate_pairing_token();
        assert_ne!(a, b);
        assert!(crate::security::validate_token_format(&a).is_ok());
    }
}
