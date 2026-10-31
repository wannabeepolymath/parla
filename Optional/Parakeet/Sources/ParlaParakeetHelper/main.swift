import Darwin
import ParakeetHelper

// No model/session is constructed until the bounded runner validates its request,
// starts independent control-EOF handling, and receives all original PCM.
exit(await ParakeetExecutable.run())
