export function combineFailures(operationFailure, cleanupFailure, message) {
  if (operationFailure !== undefined && cleanupFailure !== undefined) {
    if (operationFailure === cleanupFailure) return operationFailure;
    return new AggregateError([operationFailure, cleanupFailure], message);
  }
  return operationFailure ?? cleanupFailure;
}

export async function finishWithCleanup(operationFailure, cleanup, message) {
  let cleanupFailure;
  try {
    await cleanup();
  } catch (error) {
    cleanupFailure = error;
  }
  const failure = combineFailures(operationFailure, cleanupFailure, message);
  if (failure !== undefined) throw failure;
}

export async function runWithCleanup(operation, cleanup, message) {
  let result;
  let operationFailure;
  try {
    result = await operation();
  } catch (error) {
    operationFailure = error;
  }
  await finishWithCleanup(operationFailure, cleanup, message);
  return result;
}

export function runWithCleanupSync(operation, cleanup, message) {
  let result;
  let operationFailure;
  try {
    result = operation();
  } catch (error) {
    operationFailure = error;
  }
  let cleanupFailure;
  try {
    cleanup();
  } catch (error) {
    cleanupFailure = error;
  }
  const failure = combineFailures(operationFailure, cleanupFailure, message);
  if (failure !== undefined) throw failure;
  return result;
}
