import { NavLink, Outlet, useNavigate } from 'react-router-dom'
import { useAuth } from '../contexts/AuthContext'
import { Button } from '@/components/ui/button'
import { Separator } from '@/components/ui/separator'

const navItems = [
  { to: '/admin/dlq', label: 'Dead Letter Queue' },
  { to: '/admin/notifications', label: 'Notifications' },
]

export default function AdminLayout() {
  const { logout } = useAuth()
  const navigate = useNavigate()

  const handleLogout = () => {
    logout()
    navigate('/login')
  }

  return (
    <div className="flex h-screen bg-background">
      {/* Sidebar */}
      <aside className="w-56 flex flex-col border-r bg-sidebar text-sidebar-foreground">
        <div className="p-4">
          <h1 className="font-semibold text-lg">Admin Panel</h1>
        </div>
        <Separator />
        <nav className="flex-1 p-2 space-y-1">
          {navItems.map(({ to, label }) => (
            <NavLink
              key={to}
              to={to}
              className={({ isActive }) =>
                `block px-3 py-2 rounded-md text-sm transition-colors ${
                  isActive
                    ? 'bg-sidebar-accent text-sidebar-accent-foreground font-medium'
                    : 'hover:bg-sidebar-accent/60'
                }`
              }
            >
              {label}
            </NavLink>
          ))}
        </nav>
        <Separator />
        <div className="p-3">
          <Button variant="ghost" className="w-full justify-start text-sm" onClick={handleLogout}>
            Logout
          </Button>
        </div>
      </aside>

      {/* Main content */}
      <div className="flex-1 flex flex-col overflow-hidden">
        <header className="h-12 flex items-center px-6 border-b">
          <span className="text-sm text-muted-foreground">Haskell Service Admin</span>
        </header>
        <main className="flex-1 overflow-auto p-6">
          <Outlet />
        </main>
      </div>
    </div>
  )
}
