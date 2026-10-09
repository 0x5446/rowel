/** Test harness surface: the reference phone plus the fixtures that stand up a full stack. */

export { HandshakeRefused, RowelPhone, type CallResult, type PhoneOptions, type PhoneStream, type StreamOutcome } from './phone.ts'
export { startStack, waitFor, type Stack, type StackOptions } from './stack.ts'
export { FakeAgent, type RecordedCall, type RecordedStream } from './fake-agent.ts'
export { dshBinary, modelAllowed, startDsh, type ThrowawayDsh } from './dsh.ts'
