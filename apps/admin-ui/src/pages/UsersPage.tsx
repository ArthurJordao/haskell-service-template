import { useState, useEffect, useCallback } from 'react'
import { toast } from 'sonner'
import * as usersApi from '../api/users'
import type { ScopeInfo, UserWithScopes } from '../types/in/Users'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'

export default function UsersPage() {
  const [users, setUsers] = useState<UserWithScopes[]>([])
  const [scopeCatalog, setScopeCatalog] = useState<ScopeInfo[]>([])
  const [loading, setLoading] = useState(false)

  // Edit dialog state
  const [editingUser, setEditingUser] = useState<UserWithScopes | null>(null)
  const [selectedScopes, setSelectedScopes] = useState<Set<string>>(new Set())
  const [saving, setSaving] = useState(false)

  const fetchData = useCallback(async () => {
    setLoading(true)
    try {
      const [usersData, scopesData] = await Promise.all([
        usersApi.listUsers(),
        usersApi.listScopes(),
      ])
      setUsers(usersData)
      setScopeCatalog(scopesData)
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Failed to load data')
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    fetchData()
  }, [fetchData])

  const openEditDialog = (user: UserWithScopes) => {
    setEditingUser(user)
    setSelectedScopes(new Set(user.scopes))
  }

  const closeEditDialog = () => {
    setEditingUser(null)
    setSelectedScopes(new Set())
  }

  const toggleScope = (scopeName: string) => {
    setSelectedScopes(prev => {
      const next = new Set(prev)
      if (next.has(scopeName)) {
        next.delete(scopeName)
      } else {
        next.add(scopeName)
      }
      return next
    })
  }

  const handleSaveScopes = async () => {
    if (!editingUser) return
    setSaving(true)
    try {
      await usersApi.setUserScopes(editingUser.id, [...selectedScopes])
      toast.success('Scopes updated — user will be re-authenticated shortly')
      closeEditDialog()
      await fetchData()
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Failed to update scopes')
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h2 className="text-2xl font-semibold">Users</h2>
        <Button variant="outline" onClick={fetchData} disabled={loading}>
          {loading ? 'Loading…' : 'Refresh'}
        </Button>
      </div>

      <div className="rounded-md border">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>ID</TableHead>
              <TableHead>Email</TableHead>
              <TableHead>Scopes</TableHead>
              <TableHead>Actions</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {users.length === 0 ? (
              <TableRow>
                <TableCell colSpan={4} className="text-center text-muted-foreground py-8">
                  {loading ? 'Loading…' : 'No users found'}
                </TableCell>
              </TableRow>
            ) : (
              users.map(user => (
                <TableRow key={user.id}>
                  <TableCell className="font-mono text-xs">{user.id}</TableCell>
                  <TableCell>{user.email}</TableCell>
                  <TableCell>
                    <div className="flex flex-wrap gap-1">
                      {user.scopes.length === 0 ? (
                        <span className="text-xs text-muted-foreground">No scopes</span>
                      ) : (
                        user.scopes.map(scope => (
                          <Badge key={scope} variant="secondary" className="text-xs">
                            {scope}
                          </Badge>
                        ))
                      )}
                    </div>
                  </TableCell>
                  <TableCell>
                    <Button size="sm" variant="outline" onClick={() => openEditDialog(user)}>
                      Edit scopes
                    </Button>
                  </TableCell>
                </TableRow>
              ))
            )}
          </TableBody>
        </Table>
      </div>

      {/* Edit scopes dialog */}
      <Dialog open={!!editingUser} onOpenChange={open => { if (!open) closeEditDialog() }}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Edit scopes</DialogTitle>
            <DialogDescription>
              {editingUser
                ? `Assign scopes for ${editingUser.email}. Changes take effect immediately — existing tokens will be invalidated.`
                : ''}
            </DialogDescription>
          </DialogHeader>

          <div className="space-y-3 py-2">
            {scopeCatalog.map(scope => (
              <label key={scope.id} className="flex items-start gap-3 cursor-pointer">
                <input
                  type="checkbox"
                  className="mt-0.5"
                  checked={selectedScopes.has(scope.name)}
                  onChange={() => toggleScope(scope.name)}
                />
                <div className="space-y-0.5">
                  <span className="font-mono text-sm">{scope.name}</span>
                  <p className="text-xs text-muted-foreground">{scope.description}</p>
                </div>
              </label>
            ))}
            {scopeCatalog.length === 0 && (
              <p className="text-sm text-muted-foreground">No scopes defined in catalog.</p>
            )}
          </div>

          <DialogFooter>
            <Button variant="outline" onClick={closeEditDialog} disabled={saving}>
              Cancel
            </Button>
            <Button onClick={handleSaveScopes} disabled={saving}>
              {saving ? 'Saving…' : 'Save'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}
