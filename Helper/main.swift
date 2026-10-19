import Foundation
import Darwin

do { try write(); print("USB is ready. Verification passed; device ejected.") }
catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
