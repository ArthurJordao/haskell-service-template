import { apiFetch } from './client'
import type { DeadLetterRecord, DLQStats, ReplayResult } from '../types'

const DLQ_URL = import.meta.env.VITE_DLQ_URL as string

export async function listMessages(params: {
  status?: string
  topic?: string
  error_type?: string
}): Promise<DeadLetterRecord[]> {
  const query = new URLSearchParams()
  if (params.status) query.set('status', params.status)
  if (params.topic) query.set('topic', params.topic)
  if (params.error_type) query.set('error_type', params.error_type)
  const qs = query.toString()
  return apiFetch<DeadLetterRecord[]>(DLQ_URL, `/dlq${qs ? `?${qs}` : ''}`)
}

export async function getStats(): Promise<DLQStats> {
  return apiFetch<DLQStats>(DLQ_URL, '/dlq/stats')
}

export async function replay(id: number): Promise<ReplayResult> {
  return apiFetch<ReplayResult>(DLQ_URL, `/dlq/${id}/replay`, { method: 'POST' })
}

export async function replayBatch(ids: number[]): Promise<ReplayResult[]> {
  return apiFetch<ReplayResult[]>(DLQ_URL, '/dlq/replay-batch', {
    method: 'POST',
    body: JSON.stringify(ids),
  })
}

export async function discard(id: number): Promise<void> {
  return apiFetch<void>(DLQ_URL, `/dlq/${id}/discard`, { method: 'POST' })
}
