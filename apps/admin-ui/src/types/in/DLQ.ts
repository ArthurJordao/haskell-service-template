export interface DeadLetterRecord {
  id: number
  originalTopic: string
  originalMessage: string
  originalHeaders: string
  errorType: string
  errorDetails: string
  correlationId: string
  createdAt: string
  retryCount: number
  status: string
  replayedAt: string | null
  replayedBy: string | null
  replayResult: string | null
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
  message: string | null
}
