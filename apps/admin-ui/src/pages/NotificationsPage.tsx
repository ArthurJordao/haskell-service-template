import { Fragment, useState } from 'react'
import { toast } from 'sonner'
import * as notificationsApi from '../api/notifications'
import type { SentNotification } from '../types/in/Notifications'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'

export default function NotificationsPage() {
  const [recipient, setRecipient] = useState('')
  const [records, setRecords] = useState<SentNotification[]>([])
  const [loading, setLoading] = useState(false)
  const [expandedId, setExpandedId] = useState<number | null>(null)
  const [searched, setSearched] = useState(false)

  const handleSearch = async () => {
    if (!recipient.trim()) {
      toast.error('Please enter a recipient')
      return
    }
    setLoading(true)
    setSearched(true)
    try {
      const data = await notificationsApi.listNotifications(recipient.trim())
      setRecords(data)
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Failed to load notifications')
    } finally {
      setLoading(false)
    }
  }

  const toggleExpand = (id: number) => {
    setExpandedId(prev => (prev === id ? null : id))
  }

  return (
    <div className="space-y-6">
      <h2 className="text-2xl font-semibold">Notifications</h2>

      <div className="flex gap-3 items-end">
        <Input
          className="w-72"
          placeholder="Recipient (email or ID)"
          value={recipient}
          onChange={e => setRecipient(e.target.value)}
          onKeyDown={e => { if (e.key === 'Enter') handleSearch() }}
        />
        <Button onClick={handleSearch} disabled={loading}>
          {loading ? 'Searching…' : 'Search'}
        </Button>
      </div>

      {searched && (
        <div className="rounded-md border">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>ID</TableHead>
                <TableHead>Template</TableHead>
                <TableHead>Channel</TableHead>
                <TableHead>Recipient</TableHead>
                <TableHead>Sent At</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {records.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={5} className="text-center text-muted-foreground py-8">
                    {loading ? 'Loading…' : 'No notifications found'}
                  </TableCell>
                </TableRow>
              ) : (
                records.map(r => (
                  <Fragment key={r.id}>
                    <TableRow
                      className="cursor-pointer hover:bg-muted/50"
                      onClick={() => toggleExpand(r.id)}
                    >
                      <TableCell className="font-mono text-xs">{r.id}</TableCell>
                      <TableCell className="text-sm">{r.templateName}</TableCell>
                      <TableCell className="text-sm">{r.channelType}</TableCell>
                      <TableCell className="text-sm">{r.recipient}</TableCell>
                      <TableCell className="text-xs">
                        {new Date(r.createdAt).toLocaleString()}
                      </TableCell>
                    </TableRow>

                    {expandedId === r.id && (
                      <TableRow className="bg-muted/30">
                        <TableCell colSpan={5} className="p-4">
                          <div className="grid grid-cols-1 md:grid-cols-2 gap-4 text-sm">
                            <div className="space-y-1">
                              <p className="font-medium text-muted-foreground">Correlation ID</p>
                              <p className="font-mono text-xs break-all">{r.createdByCid}</p>
                            </div>
                            <div className="space-y-1 md:col-span-2">
                              <p className="font-medium text-muted-foreground">Content</p>
                              <pre className="text-xs bg-background rounded p-3 border overflow-x-auto whitespace-pre-wrap break-all">
                                {r.content}
                              </pre>
                            </div>
                          </div>
                        </TableCell>
                      </TableRow>
                    )}
                  </Fragment>
                ))
              )}
            </TableBody>
          </Table>
        </div>
      )}
    </div>
  )
}
