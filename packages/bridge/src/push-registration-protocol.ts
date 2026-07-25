export const PUSH_REGISTRATION_STATUS_CAPABILITY =
  "push_registration_status_v1";
export const PUSH_REGISTRATION_STATE_MESSAGE = "push_registration_state_v1";

export interface PushRegistrationStateMessage {
  type: typeof PUSH_REGISTRATION_STATE_MESSAGE;
  operation: "register" | "unregister";
  requestId: string;
  success: boolean;
  errorCode?: "relay_unavailable" | "registration_failed";
}
