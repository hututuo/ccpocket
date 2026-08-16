export const FILE_TRANSFER_CAPABILITY = "file_transfer_v2";
export const FILE_TRANSFER_DIAGNOSTIC_REPORT_CAPABILITY =
  "file_transfer_diagnostic_report_v1";
export const FILE_TRANSFER_DIAGNOSTIC_REPORT_NO_STEP_UP_CAPABILITY =
  "file_transfer_diagnostic_report_no_step_up_v1";
export const FILE_TRANSFER_MAX_FILE_SIZE_BYTES = 15 * 1024 * 1024 * 1024;
export const FILE_TRANSFER_MAX_UPLOAD_CHUNK_BYTES = 16 * 1024 * 1024;
export const FILE_TRANSFER_TOKEN_PATTERN = /^[A-Za-z0-9_-]{43}$/;
export const FILE_TRANSFER_ID_PATTERN = /^[A-Za-z0-9_-]{16,128}$/;
export const FILE_TRANSFER_ETAG_PATTERN = /^"[A-Za-z0-9_-]{32}"$/;
