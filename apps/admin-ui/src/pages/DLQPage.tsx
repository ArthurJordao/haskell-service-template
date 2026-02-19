import { useState, useEffect, useCallback } from 'react'
import { toast } from 'sonner'
import * as dlqApi from '../api/dlq'
import type { DeadLetterRecord, DLQStats } from '../types'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'

const STATUS_OPTIONS = [
  { value: 'all', label: 'All statuses' },
  { value: 'pending', label: 'pending' },
  { value: 'replayed', label: 'replayed' },
  { value: 'discarded', label: 'discarded' },
] as const

function statusVariant(status: string): 'default' | 'secondary' | 'destructive' | 'outline' {
  switch (status) {
    case 'pending': return 'destructive'
    case 'replayed': return 'default'
    case 'discarded': return 'secondary'
    default: return 'outline'
  }
}

export default function DLQPage() {
  const [stats, setStats] = useState<DLQStats | null>(null)
  const [records, setRecords] = useState<DeadLetterRecord[]>([])
  const [loading, setLoading] = useState(false)

  // Filters — 'all' is the sentinel for "no filter"
  const [filterStatus, setFilterStatus] = useState('all')
  const [filterTopic, setFilterTopic] = useState('')
  const [filterErrorType, setFilterErrorType] = useState('')

  // Selection
  const [selected, setSelected] = useState<Set<number>>(new Set())

  // Confirm dialog
  const [confirmAction, setConfirmAction] = useState<{
    type: 'replay' | 'discard'
    ids: number[]
  } | null>(null)

  const fetchData = useCallback(async () => {
    setLoading(true)
    try {
      const [statsData, recordsData] = await Promise.all([
        dlqApi.getStats(),
        dlqApi.listMessages({
          status: filterStatus !== 'all' ? filterStatus : undefined,
          topic: filterTopic || undefined,
          error_type: filterErrorType || undefined,
        }),
      ])
      setStats(statsData)
      setRecords(recordsData)
      setSelected(new Set())
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Failed to load data')
    } finally {
      setLoading(false)
    }
  }, [filterStatus, filterTopic, filterErrorType])

  useEffect(() => { fetchData() }, [fetchData])

  const resetFilters = () => {
    setFilterStatus('all')
    setFilterTopic('')
    setFilterErrorType('')
  }

  const toggleSelect = (id: number) => {
    setSelected(prev => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  const toggleAll = () => {
    if (selected.size === records.length) setSelected(new Set())
    else setSelected(new Set(records.map(r => r.dlrId)))
  }

  const handleConfirm = async () => {
    if (!confirmAction) return
    const { type, ids } = confirmAction
    setConfirmAction(null)
    try {
      if (type === 'replay') {
        if (ids.length === 1) {
          await dlqApi.replay(ids[0])
        } else {
          await dlqApi.replayBatch(ids)
        }
        toast.success(`Replayed ${ids.length} message(s)`)
      } else {
        await Promise.all(ids.map(id => dlqApi.discard(id)))
        toast.success(`Discarded ${ids.length} message(s)`)
      }
      await fetchData()
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Action failed')
    }
  }

  const statCards = stats
    ? [
        { label: 'Total', value: stats.total },
        { label: 'Pending', value: stats.pending },
        { label: 'Replayed', value: stats.replayed },
        { label: 'Discarded', value: stats.discarded },
      ]
    : []

  return (
    <div className="space-y-6">
      <h2 className="text-2xl font-semibold">Dead Letter Queue</h2>

      {/* Stats */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        {statCards.map(({ label, value }) => (
          <Card key={label}>
            <CardHeader className="pb-1 pt-4 px-4">
              <CardTitle className="text-sm font-medium text-muted-foreground">{label}</CardTitle>
            </CardHeader>
            <CardContent className="pb-4 px-4">
              <p className="text-3xl font-bold">{value}</p>
            </CardContent>
          </Card>
        ))}
      </div>

      {/* Filters */}
      <div className="flex flex-wrap gap-3 items-end">
        <div className="w-40">
          <Select value={filterStatus} onValueChange={setFilterStatus}>
            <SelectTrigger>
              <SelectValue placeholder="All statuses" />
            </SelectTrigger>
            <SelectContent>
              {STATUS_OPTIONS.map(({ value, label }) => (
                <SelectItem key={value} value={value}>
                  {label}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <Input
          className="w-48"
          placeholder="Topic"
          value={filterTopic}
          onChange={e => setFilterTopic(e.target.value)}
        />
        <Input
          className="w-48"
          placeholder="Error type"
          value={filterErrorType}
          onChange={e => setFilterErrorType(e.target.value)}
        />
        <Button variant="outline" onClick={resetFilters}>Reset</Button>
        <Button variant="outline" onClick={fetchData} disabled={loading}>
          {loading ? 'Loading…' : 'Refresh'}
        </Button>
        {selected.size > 0 && (
          <>
            <Button
              size="sm"
              onClick={() => setConfirmAction({ type: 'replay', ids: [...selected] })}
            >
              Replay Selected ({selected.size})
            </Button>
            <Button
              size="sm"
              variant="destructive"
              onClick={() => setConfirmAction({ type: 'discard', ids: [...selected] })}
            >
              Discard Selected ({selected.size})
            </Button>
          </>
        )}
      </div>

      {/* Table */}
      <div className="rounded-md border">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead className="w-10">
                <input
                  type="checkbox"
                  checked={selected.size === records.length && records.length > 0}
                  onChange={toggleAll}
                />
              </TableHead>
              <TableHead>ID</TableHead>
              <TableHead>Topic</TableHead>
              <TableHead>Error Type</TableHead>
              <TableHead>Status</TableHead>
              <TableHead>Retries</TableHead>
              <TableHead>Created At</TableHead>
              <TableHead>Actions</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {records.length === 0 ? (
              <TableRow>
                <TableCell colSpan={8} className="text-center text-muted-foreground py-8">
                  {loading ? 'Loading…' : 'No records found'}
                </TableCell>
              </TableRow>
            ) : (
              records.map(r => (
                <TableRow key={r.dlrId}>
                  <TableCell>
                    <input
                      type="checkbox"
                      checked={selected.has(r.dlrId)}
                      onChange={() => toggleSelect(r.dlrId)}
                    />
                  </TableCell>
                  <TableCell className="font-mono text-xs">{r.dlrId}</TableCell>
                  <TableCell className="max-w-[160px] truncate text-sm">{r.dlrOriginalTopic}</TableCell>
                  <TableCell className="max-w-[160px] truncate text-sm">{r.dlrErrorType}</TableCell>
                  <TableCell>
                    <Badge variant={statusVariant(r.dlrStatus)}>{r.dlrStatus}</Badge>
                  </TableCell>
                  <TableCell>{r.dlrRetryCount}</TableCell>
                  <TableCell className="text-xs">
                    {new Date(r.dlrCreatedAt).toLocaleString()}
                  </TableCell>
                  <TableCell>
                    <div className="flex gap-2">
                      <Button
                        size="sm"
                        variant="outline"
                        onClick={() => setConfirmAction({ type: 'replay', ids: [r.dlrId] })}
                        disabled={r.dlrStatus !== 'pending'}
                      >
                        Replay
                      </Button>
                      <Button
                        size="sm"
                        variant="destructive"
                        onClick={() => setConfirmAction({ type: 'discard', ids: [r.dlrId] })}
                        disabled={r.dlrStatus === 'discarded'}
                      >
                        Discard
                      </Button>
                    </div>
                  </TableCell>
                </TableRow>
              ))
            )}
          </TableBody>
        </Table>
      </div>

      {/* Confirm dialog */}
      <Dialog open={!!confirmAction} onOpenChange={open => { if (!open) setConfirmAction(null) }}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>
              {confirmAction?.type === 'replay' ? 'Replay' : 'Discard'} messages
            </DialogTitle>
            <DialogDescription>
              {confirmAction?.type === 'replay'
                ? `Re-publish ${confirmAction.ids.length} message(s) to their original topics?`
                : `Mark ${confirmAction?.ids.length} message(s) as discarded? This cannot be undone.`}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setConfirmAction(null)}>Cancel</Button>
            <Button
              variant={confirmAction?.type === 'discard' ? 'destructive' : 'default'}
              onClick={handleConfirm}
            >
              Confirm
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}
