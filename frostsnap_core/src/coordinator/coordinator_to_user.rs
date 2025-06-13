use super::*;
use frostsnap_macros::Kind;

#[derive(Clone, Debug, Kind)]
pub enum CoordinatorToUserMessage {
    Keygen {
        keygen_id: KeygenId,
        inner: CoordinatorToUserKeygenMessage,
    },
    Signing(CoordinatorToUserSigningMessage),
    Restoration(super::restoration::ToUserRestoration),
}

impl Gist for CoordinatorToUserMessage {
    fn gist(&self) -> String {
        crate::Kind::kind(self).into()
    }
}

#[derive(Clone, Debug)]
pub enum CoordinatorToUserSigningMessage {
    GotShare {
        session_id: SignSessionId,
        from: DeviceId,
    },
    Signed {
        session_id: SignSessionId,
        signatures: Vec<EncodedSignature>,
    },
}

#[derive(Clone, Debug)]
pub enum CoordinatorToUserKeygenMessage {
    ReceivedShares {
        from: DeviceId,
    },
    CheckKeygen {
        session_hash: SessionHash,
    },
    KeygenAck {
        from: DeviceId,
        all_acks_received: bool,
    },
}
