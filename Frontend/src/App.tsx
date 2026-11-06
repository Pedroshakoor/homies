import { useEffect, useRef, useState } from 'react'
import type { ReactNode } from 'react'
import { ArrowDownLeft, ArrowUpRight, Check, ChevronDown, Clock3, Copy, Ellipsis, FolderOpen, LogIn, RefreshCw, Search, Square, AudioLines, Paperclip, CircleDot, CornerDownLeft, SquarePen, X } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Textarea } from '@/components/ui/textarea'
import { Avatar, AvatarImage, AvatarFallback } from '@/components/ui/avatar'
import { ScrollArea } from '@/components/ui/scroll-area'
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription } from '@/components/ui/dialog'
import { DropdownMenu, DropdownMenuContent, DropdownMenuTrigger, DropdownMenuRadioGroup, DropdownMenuRadioItem, DropdownMenuSeparator, DropdownMenuItem } from '@/components/ui/dropdown-menu'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from '@/components/ui/tooltip'
import { Separator } from '@/components/ui/separator'
import { Switch } from '@/components/ui/switch'
import './App.css'

type Attachment = { id: string; name: string; path: string; kind: string; previewURL?: string }
type Message = { id: string; role: 'user' | 'assistant' | 'notice'; text: string; date: number; attachments?: Attachment[]; voiceNote?: { duration: number; audioURL: string; transcript?: string } }
type Agent = { id: string; name: string; kind: string; draft: string; draftVersion: number; draftOrigin: string; status: string; statusLabel: string; running: boolean; retryable: boolean; error: string | null; activity: string; loginStatus: string; signedIn: boolean; checkingLogin: boolean; workingDirectory: string; binaryPath: string; retention: number; model: string; models: { id: string; name: string }[]; modelError: string | null; messages: Message[]; attachments?: Attachment[]; captureTargets?: { id: string; label: string; kind: string }[]; allowProjectEdits: boolean }
type NativeState = { selectedId: string; agents: Agent[]; expanded: boolean; dark: boolean; accent: string; voice?: { state: 'idle' | 'recording' | 'transcribing' | 'error'; levels: number[]; error?: string }; hotkey?: { keyCode: number; modifiers: number; label: string } }
type Chat = { id: string; name: string; preview: string; cwd: string; date: number; active: boolean }
type HistoryResult = { chats?: Chat[]; cursor?: string | null; append?: boolean; error?: string; resumed?: boolean }
declare global {
  interface Window {
    webkit?: { messageHandlers: { agentdrop: { postMessage: (payload: Record<string, unknown>) => void } } }
    agentDrop: { receive: (state: NativeState) => void; history: (result: HistoryResult) => void }
  }
}
const retentionOptions = [{ value: 0, label: 'Never' }, { value: 1, label: '1 day' }, { value: 3, label: '3 days' }, { value: 7, label: '1 week' }, { value: 30, label: '1 month' }]
const clientId = `${Date.now()}-${Math.random().toString(36).slice(2)}`
const post = (action: string, payload: Record<string, unknown> = {}) => window.webkit?.messageHandlers.agentdrop.postMessage({ action, client: clientId, ...payload })
const logo = (agent: Agent) => agent.kind === 'codex' ? './openai.svg' : agent.kind === 'hermes' ? './hermes.svg' : './claude.svg'
const dateLabel = (timestamp: number) => {
  const date = new Date(timestamp * 1000)
  const today = date.toDateString() === new Date().toDateString()
  return `${today ? 'Today' : date.toLocaleDateString(undefined, { day: 'numeric', month: 'short' })} ${date.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' })}`
}
function Profile({ agent, small = false }: { agent: Agent; small?: boolean }) {
  return <Avatar data-agent={agent.kind} className={small ? 'profile profile-small' : 'profile'}><AvatarImage src={logo(agent)} alt={`${agent.name} official logo`} /><AvatarFallback>{agent.name.slice(0, 1)}</AvatarFallback></Avatar>
}
function IconButton({ label, children, onClick, disabled = false }: { label: string; children: ReactNode; onClick?: () => void; disabled?: boolean }) {
  return <Tooltip><TooltipTrigger asChild><span><Button variant="ghost" size="icon" className="icon-button" aria-label={label} disabled={disabled} onClick={onClick}>{children}</Button></span></TooltipTrigger><TooltipContent className="glass-tooltip" side="bottom">{label}</TooltipContent></Tooltip>
}
function ModelPicker({ agent, settings = false }: { agent: Agent; settings?: boolean }) {
  return <Select value={agent.model || 'default'} onValueChange={value => post('model', { id: agent.id, value: value === 'default' ? '' : value })} disabled={agent.running}>
    <SelectTrigger className={settings ? 'glass-select' : 'model-picker'} aria-label="Select model"><SelectValue placeholder="Your default model" /></SelectTrigger>
    <SelectContent className="glass-menu model-options" position="popper">
      <SelectItem value="default">Your default model</SelectItem>
      {agent.models.map(model => <SelectItem key={model.id} value={model.id}>{model.name}</SelectItem>)}
      {agent.model && !agent.models.some(model => model.id === agent.model) && <SelectItem value={agent.model}>{agent.model}</SelectItem>}
    </SelectContent>
  </Select>
}

export default function App() {
  const [native, setNative] = useState<NativeState | null>(null)
  const [settings, setSettings] = useState(false)
  const [history, setHistory] = useState(false)
  const [chats, setChats] = useState<Chat[]>([])
  const [search, setSearch] = useState('')
  const [historyCursor, setHistoryCursor] = useState<string | null>(null)
  const [historyBusy, setHistoryBusy] = useState(false)
  const [historyError, setHistoryError] = useState<string | null>(null)
  const [draft, setDraft] = useState('')
  const [channelSearch, setChannelSearch] = useState('')
  const bottom = useRef<HTMLDivElement>(null)
  const selectedId = useRef('')
  const draftVersions = useRef(new Map<string, number>())
  const textarea = useRef<HTMLTextAreaElement>(null)
  const agent = native?.agents.find(item => item.id === native.selectedId)
  const lastMessageText = agent?.messages.at(-1)?.text
  useEffect(() => {
    window.agentDrop = {
      receive: state => {
        setNative(state)
        document.documentElement.classList.toggle('dark', state.dark)
        document.documentElement.style.setProperty('--system-accent', state.accent)
        const current = state.agents.find(item => item.id === state.selectedId)
        if (current) {
          const previousVersion = draftVersions.current.get(current.id)
          if (selectedId.current !== current.id || previousVersion === undefined || (current.draftVersion > previousVersion && current.draftOrigin !== clientId)) setDraft(current.draft)
          draftVersions.current.set(current.id, Math.max(previousVersion ?? -1, current.draftVersion))
        }
        selectedId.current = state.selectedId
      },
      history: result => {
        setHistoryBusy(false)
        if (result.error) { setHistoryError(result.error); return }
        if (result.resumed) { setHistory(false); return }
        setHistoryError(null)
        setChats(previous => result.append ? [...previous, ...(result.chats ?? []).filter(chat => !previous.some(item => item.id === chat.id))] : result.chats ?? [])
        setHistoryCursor(result.cursor ?? null)
      },
    }
    post('ready')
  }, [])
  useEffect(() => { bottom.current?.scrollIntoView({ behavior: 'instant' }) }, [agent?.messages.length, lastMessageText, agent?.running])
  const send = () => {
    if (!agent || agent.running || (!draft.trim() && !agent.attachments?.length)) return
    post('send', { id: agent.id, text: draft })
    if (agent.workingDirectory && agent.binaryPath) setDraft('')
  }
  const importFiles = (files: FileList | File[], id: string) => {
    Array.from(files).forEach(file => {
      if (file.size > 25 * 1024 * 1024) { post('attachmentError', { id, error: 'Attachments must be 25 MB or smaller.' }); return }
      const reader = new FileReader()
      reader.onload = () => { if (typeof reader.result === 'string') post('importAttachment', { id, name: file.name || 'Pasted image.png', data: reader.result.split(',')[1] }) }
      reader.readAsDataURL(file)
    })
  }
  const loadHistory = (cursor?: string) => {
    if (!agent) return
    setHistoryBusy(true); setHistoryError(null)
    post('history', { id: agent.id, search, ...(cursor ? { cursor } : {}) })
  }
  if (!native || !agent) return <div className="app-shell loading-shell"><img src="./AppAvatar.png" alt="Piko" /><span>Opening your agents…</span></div>
  const selectAgent = (id: string) => { setSettings(false); setHistory(false); post('select', { id }); setTimeout(() => textarea.current?.focus(), 50) }
  return <TooltipProvider delayDuration={400}><main className={`app-shell ${native.expanded ? 'expanded' : ''}`} onDragOver={event => { if (event.dataTransfer.types.includes('Files')) event.preventDefault() }} onDrop={event => { if (event.dataTransfer.files.length) { event.preventDefault(); importFiles(event.dataTransfer.files, agent.id) } }} onKeyDown={event => {
    if (event.key === 'Escape' && !settings && !history && !event.defaultPrevented) post('close')
    if ((event.metaKey || event.ctrlKey) && event.key === 'Enter') { event.preventDefault(); send() }
    if (event.metaKey && event.key === '.') post('stop', { id: agent.id })
    if (event.metaKey && /^[1-9]$/.test(event.key)) { const target = native.agents[Number(event.key) - 1]; if (target) { event.preventDefault(); selectAgent(target.id) } }
  }}>
    {native.expanded && <aside className="channels"><div className="channels-title">Channels</div><div className="channel-search"><Search /><Input placeholder="Search anything…" aria-label="Search channels" value={channelSearch} onChange={event => setChannelSearch(event.target.value)} /></div><div className="channel-list">{native.agents.filter(item => `${item.name} ${item.messages.at(-1)?.text || ''}`.toLowerCase().includes(channelSearch.toLowerCase())).map(item => <Button variant="ghost" key={item.id} className={`channel-row ${item.id === agent.id ? 'selected' : ''}`} onClick={() => selectAgent(item.id)}><Profile agent={item} /><span><strong>{item.name}</strong><small>{item.messages.at(-1)?.text || item.messages.at(-1)?.attachments?.map(attachment => attachment.name).join(', ') || 'Start a conversation'}</small></span></Button>)}</div></aside>}
    <div className="workspace"><header className="agent-header">
      <Profile agent={agent} />
      <div className="agent-heading">
        <DropdownMenu><DropdownMenuTrigger asChild><Button variant="ghost" className="agent-name">{agent.name}<ChevronDown /></Button></DropdownMenuTrigger>
          <DropdownMenuContent className="glass-menu agent-menu" align="start">
            <DropdownMenuRadioGroup value={agent.id} onValueChange={selectAgent}>
              {native.agents.map(item => <DropdownMenuRadioItem value={item.id} key={item.id}><img className="menu-logo" src={logo(item)} alt="" />{item.name}</DropdownMenuRadioItem>)}
            </DropdownMenuRadioGroup>
            <DropdownMenuSeparator />
            <DropdownMenuItem onSelect={() => post('new', { id: agent.id })} disabled={agent.running}>New conversation</DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
        <div className="agent-subtitle"><Tooltip><TooltipTrigger asChild><span className={`status-dot ${!agent.signedIn ? 'needsApproval' : agent.status}`} aria-label={agent.signedIn ? agent.statusLabel : agent.loginStatus} tabIndex={0} /></TooltipTrigger><TooltipContent className="glass-tooltip">{agent.signedIn ? agent.statusLabel : agent.loginStatus}</TooltipContent></Tooltip><ModelPicker agent={agent} /></div>
      </div>
      <div className="header-actions">
        {agent.kind === 'codex' && <IconButton label="Search your Codex chats" disabled={agent.running} onClick={() => { setHistory(true); loadHistory() }}><Clock3 /></IconButton>}
        <IconButton label="Agent settings" onClick={() => { setSettings(true); post('models', { id: agent.id }) }}><Ellipsis /></IconButton>
        <IconButton label={native.expanded ? 'Show compact panel' : 'Open full window'} onClick={() => post('expand')} >{native.expanded ? <ArrowDownLeft /> : <ArrowUpRight />}</IconButton>
      </div>
    </header>
    <div className="session-tools"><Button variant="ghost" className="new-session-button" disabled={agent.running} onClick={() => post('new', { id: agent.id })}><SquarePen />New session</Button></div>
    <ScrollArea className="conversation-scroll">
      <div className="conversation">
        <DropdownMenu><DropdownMenuTrigger asChild><Button variant="ghost" className="retention-line">History <span>{agent.retention === 0 ? 'stays' : retentionOptions.find(item => item.value === agent.retention)?.label}</span> {agent.retention === 0 ? 'here.' : 'then clears.'}</Button></DropdownMenuTrigger>
          <DropdownMenuContent className="glass-menu" align="center"><DropdownMenuRadioGroup value={String(agent.retention)} onValueChange={value => post('retention', { id: agent.id, value: Number(value) })}>{retentionOptions.map(option => <DropdownMenuRadioItem value={String(option.value)} key={option.value}>{option.label}</DropdownMenuRadioItem>)}</DropdownMenuRadioGroup></DropdownMenuContent>
        </DropdownMenu>
        {!agent.messages.length && <div className="quiet-start">
          {!agent.signedIn && !agent.checkingLogin && <Button variant="ghost" className="glass-button" onClick={() => post('login', { id: agent.id })}><LogIn />{agent.kind === 'hermes' ? 'Set up Hermes' : `Log in to ${agent.name}`}</Button>}
          {!agent.workingDirectory && <Button variant="ghost" className="glass-button" onClick={() => post('folder', { id: agent.id })}><FolderOpen />Choose a working folder</Button>}
        </div>}
        {agent.messages.filter(message => message.text || message.attachments?.length || message.voiceNote).map((message, index) => <div key={message.id}>
          {index === 0 && <div className="date-separator">{dateLabel(message.date)}</div>}
          {message.role === 'notice' ? <p className="system-message">{message.text}</p> : <div className={`message-row ${message.role}`}>
            {message.role === 'assistant' && <Profile agent={agent} small />}
            <div className="message-bubble">{message.text && <p>{message.text}</p>}{message.attachments?.map(attachment => <Button variant="ghost" className="message-attachment" key={attachment.id} draggable onDragStart={() => post('dragAttachment', { id: agent.id, path: attachment.path })} onClick={() => post('revealAttachment', { id: agent.id, path: attachment.path })}>{attachment.previewURL && <img src={attachment.previewURL} alt="" />}<span>{attachment.name}</span></Button>)}{message.voiceNote && <div className="voice-note"><audio controls src={message.voiceNote.audioURL} aria-label="Voice note" />{message.voiceNote.transcript && <p>{message.voiceNote.transcript}</p>}</div>}{message.text && <Button variant="ghost" size="icon" className="message-copy" aria-label="Copy message" onClick={() => post('copy', { text: message.text })}><Copy /></Button>}</div>
            {message.role === 'user' && <Avatar className="profile profile-small user-profile"><AvatarFallback>Y</AvatarFallback></Avatar>}
          </div>}
        </div>)}
        {agent.running && <p className="activity"><span className="thinking-dot" />{agent.activity || `${agent.name} is thinking…`}</p>}{agent.status === 'needsApproval' && <Button variant="ghost" className="glass-button terminal-handoff" onClick={() => post('openSession', { id: agent.id })}>Continue in Terminal <ArrowUpRight /></Button>}
        <div ref={bottom} />
      </div>
    </ScrollArea>
    {agent.error && <div className="error-message"><p>{agent.error}</p>{!agent.running && agent.retryable && <Button variant="ghost" className="quiet-button" onClick={() => post('retry', { id: agent.id })}>Retry</Button>}<IconButton label="Dismiss error" onClick={() => post('dismissError', { id: agent.id })}><X /></IconButton></div>}
    <section className="composer" aria-label="Compose a message">
      <Textarea ref={textarea} autoFocus className="compose-textarea" aria-label={`Message to ${agent.name}`} placeholder={`Talk to ${agent.name}…`} value={draft} rows={1} onPaste={event => { const images = Array.from(event.clipboardData.files).filter(file => file.type.startsWith('image/')); if (images.length) { event.preventDefault(); importFiles(images, agent.id) } else post('pasteAttachments', { id: agent.id }) }} onChange={event => { setDraft(event.target.value); post('draft', { id: agent.id, text: event.target.value }) }} onKeyDown={event => { if (event.key === 'Enter' && !event.shiftKey) { event.preventDefault(); send() } }} />
      {!!agent.attachments?.length && <div className="attachment-list">{agent.attachments.map(attachment => <div className="attachment-chip" key={attachment.id}>{attachment.previewURL && <img src={attachment.previewURL} alt="" />}<span>{attachment.name}</span><Button variant="ghost" size="icon" aria-label={`Remove ${attachment.name}`} onClick={() => post('removeAttachment', { id: agent.id, attachmentId: attachment.id })}><X /></Button></div>)}</div>}
      {native.voice && native.voice.state !== 'idle' && <div className={`voice-status ${native.voice.state}`} role="status">{native.voice.state === 'recording' && <span className="waveform" aria-hidden="true">{(native.voice.levels.length ? native.voice.levels : [0]).map((level, index) => <i key={index} style={{ height: `${Math.max(3, Math.min(18, level * 18))}px` }} />)}</span>}{native.voice.state === 'recording' ? 'Recording' : native.voice.state === 'transcribing' ? 'Transcribing…' : native.voice.error || 'Voice error'}</div>}
      <div className="composer-actions"><div className="context-actions">
        <IconButton label={native.voice?.state === 'recording' ? 'Stop recording' : 'Record voice'} disabled={native.voice?.state === 'transcribing'} onClick={() => post(native.voice?.state === 'recording' ? 'voiceStop' : 'voiceStart', { id: agent.id })}><AudioLines /></IconButton>
        <IconButton label="Attach files" onClick={() => post('attach', { id: agent.id })}><Paperclip /></IconButton>
        <DropdownMenu onOpenChange={open => { if (open) post('captureTargets', { id: agent.id }) }}><DropdownMenuTrigger asChild><Button variant="ghost" size="icon" className="icon-button" aria-label="Capture screen"><CircleDot /></Button></DropdownMenuTrigger><DropdownMenuContent className="glass-menu" align="start"><DropdownMenuItem onSelect={() => post('captureSelection', { id: agent.id })}>Capture selection</DropdownMenuItem><DropdownMenuSeparator />{agent.captureTargets?.map(target => <DropdownMenuItem key={target.id} onSelect={() => post('capture', { id: agent.id, targetId: target.id })}>{target.label}</DropdownMenuItem>)}{!agent.captureTargets?.length && <DropdownMenuItem disabled>No capture targets</DropdownMenuItem>}</DropdownMenuContent></DropdownMenu>
      </div>
        {agent.running ? <Button variant="ghost" className="drop-button" onClick={() => post('stop', { id: agent.id })}>Stop<Square /></Button> : <Button variant="ghost" className="drop-button" disabled={!draft.trim() && !agent.attachments?.length} onClick={send}>Drop<CornerDownLeft /></Button>}
      </div>
    </section>
    </div><Dialog open={settings} onOpenChange={setSettings}><DialogContent className="glass-dialog settings-dialog translate-x-0 translate-y-0">
      <DialogHeader><div className="dialog-profile"><Profile agent={agent} /><div><DialogTitle>{agent.name}</DialogTitle><DialogDescription>Agent settings</DialogDescription></div></div></DialogHeader>
      <ScrollArea className="settings-scroll"><div className="settings-content">
        <section className="setting-section"><div className="setting-heading">Account<span className={agent.signedIn ? 'account-connected' : ''}>{agent.signedIn ? <Check /> : <LogIn />}{agent.signedIn ? 'Connected' : 'Not connected'}</span></div>
          <p className="setting-note">{agent.loginStatus}</p><div className="setting-buttons"><Button variant="ghost" className="glass-button" disabled={agent.running || agent.signedIn} onClick={() => post('login', { id: agent.id })}>{agent.signedIn ? 'Connected' : agent.kind === 'hermes' ? 'Set up Hermes' : 'Log in'}{agent.signedIn ? <Check /> : <ArrowUpRight />}</Button><IconButton label="Refresh login" onClick={() => post('refreshLogin', { id: agent.id })} disabled={agent.checkingLogin}><RefreshCw /></IconButton></div>
        </section><Separator />
        <section className="setting-section"><div className="setting-heading">Model</div><ModelPicker agent={agent} settings />{agent.kind === 'hermes' && <Button variant="ghost" className="glass-button" disabled={agent.running} onClick={() => post('configureModel', { id: agent.id })}>Set up model</Button>}{agent.modelError && <p className="setting-note error-text">{agent.modelError}</p>}</section><Separator />
        {agent.kind === 'codex' && <><section className="setting-section"><div className="setting-heading"><label htmlFor="project-edits">Allow project edits</label><Switch id="project-edits" checked={agent.allowProjectEdits} disabled={agent.running} onCheckedChange={value => post('allowProjectEdits', { id: agent.id, value })} /></div><p className="setting-note">Allows file changes inside the selected project; outside access stays blocked.</p></section><Separator /></>}
        <section className="setting-section"><div className="setting-heading">Working folder</div><p className="path-label">{agent.workingDirectory || 'Choose a project for your agent'}</p><Button variant="ghost" className="glass-button" disabled={agent.running} onClick={() => post('folder', { id: agent.id })}><FolderOpen />Choose folder</Button></section><Separator />
        <section className="setting-section"><div className="setting-heading">Executable</div><p className="path-label">{agent.binaryPath || 'Not found'}</p><Button variant="ghost" className="glass-button" disabled={agent.running} onClick={() => post('binary', { id: agent.id })}>Choose executable</Button></section><Separator />
        <section className="setting-section"><p className="setting-note">Capture + send: ⌃⌥⇧ Space. Includes your screen and selected or copied text.</p><div className="setting-heading">Hold to talk</div><Select value={native.hotkey?.keyCode === 49 ? String(native.hotkey.modifiers) : ''} onValueChange={value => post('setHotkey', { keyCode: 49, modifiers: Number(value) })}><SelectTrigger className="glass-select" aria-label="Global shortcut"><SelectValue placeholder={native.hotkey?.label || 'Choose shortcut'} /></SelectTrigger><SelectContent className="glass-menu"><SelectItem value="786432">⌃⌥ Space</SelectItem><SelectItem value="393216">⌃⇧ Space</SelectItem><SelectItem value="1179648">⌘⇧ Space</SelectItem></SelectContent></Select></section><Separator />
        <section className="setting-section"><div className="setting-heading">History clears after</div><Select value={String(agent.retention)} onValueChange={value => post('retention', { id: agent.id, value: Number(value) })}><SelectTrigger className="glass-select"><SelectValue /></SelectTrigger><SelectContent className="glass-menu">{retentionOptions.map(option => <SelectItem value={String(option.value)} key={option.value}>{option.label}</SelectItem>)}</SelectContent></Select></section>
        <div className="setting-buttons"><Button variant="ghost" className="glass-button" disabled={agent.running} onClick={() => { post('new', { id: agent.id }); setSettings(false) }}>New session</Button><Button variant="ghost" className="glass-button" onClick={() => post('reveal', { id: agent.id })}>Show files</Button></div>
        <p className="setting-note">{agent.kind === 'codex' ? 'Uses your Codex account, settings, and project context.' : agent.kind === 'claudeCode' ? 'Uses your Claude Code account. Approvals are handled in Terminal.' : 'Hermes uses your configured provider. Model changes start a new session.'}</p>
        <Button variant="ghost" className="quiet-button" onClick={() => post('quit')}>Quit Piko</Button>
      </div></ScrollArea>
    </DialogContent></Dialog>
    <Dialog open={history} onOpenChange={setHistory}><DialogContent className="glass-dialog history-dialog translate-x-0 translate-y-0">
      <DialogHeader><DialogTitle>Your Codex chats</DialogTitle><DialogDescription>Pick up where you left off.</DialogDescription></DialogHeader>
      <form className="search-card" onSubmit={event => { event.preventDefault(); loadHistory() }}><Search /><Input className="chat-search" placeholder="Search anything…" aria-label="Search Codex chats" value={search} onChange={event => setSearch(event.target.value)} /><Button variant="ghost" size="icon" className="icon-button" type="submit" aria-label="Search"><CornerDownLeft /></Button></form>
      {historyError && <p className="error-text setting-note">{historyError}</p>}
      <ScrollArea className="history-scroll"><div className="chat-list">{chats.map(chat => <Button variant="ghost" className="chat-row" key={chat.id} disabled={historyBusy || chat.active} onClick={() => { setHistoryBusy(true); post('resume', { id: agent.id, chatId: chat.id }) }}><Profile agent={agent} /><span className="chat-copy"><span className="chat-title">{chat.name}</span><span className="chat-preview">{chat.preview}</span><span className="chat-folder">{chat.cwd.split('/').filter(Boolean).at(-1)}</span></span><span className="chat-date">{new Date(chat.date * 1000).toLocaleDateString(undefined, { month: 'short', day: 'numeric' })}</span></Button>)}{!chats.length && !historyBusy && <p className="empty-history">No matching chats.</p>}</div></ScrollArea>
      <div className="history-footer"><span>{historyBusy ? 'Loading…' : `${chats.length} conversations`}</span>{historyCursor && <Button variant="ghost" className="glass-button" disabled={historyBusy} onClick={() => loadHistory(historyCursor)}>Load more</Button>}</div>
    </DialogContent></Dialog>
  </main></TooltipProvider>
}
