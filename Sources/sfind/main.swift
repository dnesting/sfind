import Foundation
import SFindCore

let status = SFindCLI.run(
    arguments: Array(CommandLine.arguments.dropFirst()), sink: FileHandleSink())
exit(status)
