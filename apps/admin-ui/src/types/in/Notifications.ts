export interface SentNotification {
  id: number
  templateName: string
  channelType: string
  recipient: string
  content: string
  createdAt: string
  createdByCid: string
}
