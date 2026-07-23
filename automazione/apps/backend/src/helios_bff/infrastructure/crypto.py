from cryptography.fernet import Fernet, InvalidToken


class FernetSecretProtector:
    def __init__(self, key: str) -> None:
        if not key:
            raise ValueError("SESSION_ENCRYPTION_KEY is required")
        try:
            self._fernet = Fernet(key.encode("ascii"))
        except (ValueError, TypeError) as exc:
            raise ValueError("SESSION_ENCRYPTION_KEY is invalid") from exc

    def encrypt(self, value: str) -> str:
        return self._fernet.encrypt(value.encode("utf-8")).decode("ascii")

    def decrypt(self, value: str) -> str:
        try:
            return self._fernet.decrypt(value.encode("ascii")).decode("utf-8")
        except (InvalidToken, ValueError, UnicodeError) as exc:
            raise ValueError("protected value is invalid") from exc
