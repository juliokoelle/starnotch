import NotchKit
import NotchCore

// The public build links the run log connector (loops from a log file, off until one is set)
// and the notes connector (a Markdown vault, off until a folder is picked); a private build adds
// its own (see docs/SDK.md).
NotchApp.main(connectors: [RunLogConnector.self, VaultConnector.self])
