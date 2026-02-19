export interface DeadLetterRecord {
  dlrId: number
  dlrOriginalTopic: string
  dlrOriginalMessage: string
  dlrOriginalHeaders: string
  dlrErrorType: string
  dlrErrorDetails: string
  dlrCorrelationId: string
  dlrCreatedAt: string
  dlrRetryCount: number
  dlrStatus: string
  dlrReplayedAt: string | null
  dlrReplayedBy: string | null
  dlrReplayResult: string | null
}

export interface DLQStats {
  total: number
  pending: number
  replayed: number
  discarded: number
}

export interface ReplayResult {
  id: number
  success: boolean
  message: string
}

export interface TokenResponse {
  accessToken: string
  refreshToken: string
  expiresIn: number
}
