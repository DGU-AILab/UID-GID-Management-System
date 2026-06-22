class UidManagerError(Exception):
    """Base exception for expected operational failures."""


class ValidationError(UidManagerError):
    """Invalid user input or configuration."""


class NotFoundError(UidManagerError):
    """Requested DB or remote resource was not found."""


class AmbiguousMatchError(UidManagerError):
    """A lookup matched more than one resource."""


class RemoteCommandError(UidManagerError):
    """Remote command execution failed."""
