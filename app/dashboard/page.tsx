'use client'

import { useEffect, useRef, useCallback } from 'react'
import { createClient } from '@/lib/supabase/client'
import { useRouter } from 'next/navigation'

export default function DashboardPage() {
  const iframeRef = useRef<HTMLIFrameElement>(null)
  const router = useRouter()

  const initApp = useCallback(async () => {
    const supabase = createClient()
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) { router.replace('/login'); return }

    // Load profile from DB
    const { data: profile } = await supabase
      .from('profiles')
      .select('*')
      .eq('id', user.id)
      .single()

    const frame = iframeRef.current
    if (!frame) return

    const payload = {
      type: 'TUTOR_HUB_INIT',
      supabaseUrl: process.env.NEXT_PUBLIC_SUPABASE_URL!,
      supabaseKey: process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
      user: {
        id: user.id,
        email: user.email ?? '',
        role: profile?.role ?? 'Pending',
        name: profile?.name
          ?? user.user_metadata?.full_name
          ?? user.user_metadata?.name
          ?? user.email?.split('@')[0]
          ?? 'User',
        avatar: profile?.avatar ?? '',
        subject: profile?.subject ?? '',
        language: profile?.language ?? 'vi',
      },
    }

    const send = () => frame.contentWindow?.postMessage(payload, window.location.origin)

    // Send as soon as the iframe is ready
    if (frame.contentDocument?.readyState === 'complete') {
      send()
    } else {
      frame.addEventListener('load', send, { once: true })
    }
  }, [router])

  useEffect(() => {
    initApp()

    // Handle messages back from the iframe
    function handleMessage(e: MessageEvent) {
      if (e.origin !== window.location.origin) return
      if (e.data?.type === 'TUTOR_HUB_LOGOUT') {
        const supabase = createClient()
        supabase.auth.signOut().then(() => {
          router.replace('/login')
        })
      }
      if (e.data?.type === 'TUTOR_HUB_SAVE_PROFILE') {
        const supabase = createClient()
        supabase.from('profiles').upsert(e.data.profile).then(() => {})
      }
    }

    window.addEventListener('message', handleMessage)
    return () => window.removeEventListener('message', handleMessage)
  }, [initApp, router])

  return (
    <iframe
      ref={iframeRef}
      src="/tutor-hub-app.html"
      style={{ width: '100vw', height: '100vh', border: 'none', display: 'block' }}
      title="Tutor Hub"
    />
  )
}
