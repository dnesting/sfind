import Foundation
import SFindCore

// Scaffold entry point. The real pipeline (OptionParser → Planner → MDQuerySource →
// PostFilter → Actions) lands per PLAN.md milestones.
FileHandle.standardError.write(
    Data("sfind \(SFind.version): not implemented yet; see SPEC.md\n".utf8))
exit(1)
