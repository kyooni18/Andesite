import Foundation

// Fail closed: accepting requests before recovery and authentication exist would
// imply guarantees that the implementation cannot yet provide.
FileHandle.standardError.write(Data("AndesiteServer is not ready: storage recovery and authentication are not implemented.\n".utf8))
exit(1)
