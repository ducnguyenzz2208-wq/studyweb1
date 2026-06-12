import { createClient } from '@/lib/supabase/server'
import { NextResponse } from 'next/server'

export async function GET(request: Request) {
  const { searchParams, origin } = new URL(request.url)
  const code = searchParams.get('code')
  const next = searchParams.get('next') ?? '/dashboard'

  if (code) {
    const supabase = await createClient()
    const { error } = await supabase.auth.exchangeCodeForSession(code)

    if (!error) {
      // Ensure profile row exists — safety net for Google OAuth (trigger may race)
      const { data: { user } } = await supabase.auth.getUser()
      if (user) {
        const rawName = user.user_metadata?.full_name
          ?? user.user_metadata?.name
          ?? user.email?.split('@')[0]
          ?? 'User'
        const avatar = rawName.split(' ').filter(Boolean).map((w: string) => w[0].toUpperCase()).join('').slice(0, 2)

        // Don't pass role — the DB trigger (handle_new_user + enforce_admin_email) is
        // the sole source of truth. ignoreDuplicates keeps existing rows untouched.
        await supabase.from('profiles').upsert(
          {
            id: user.id,
            email: user.email ?? '',
            name: rawName,
            avatar,
            language: 'vi',
          },
          { onConflict: 'id', ignoreDuplicates: true }
        )
      }

      const forwardedHost = request.headers.get('x-forwarded-host')
      const forwardedProto = request.headers.get('x-forwarded-proto') ?? 'https'
      const redirectBase = forwardedHost ? `${forwardedProto}://${forwardedHost}` : origin
      return NextResponse.redirect(`${redirectBase}${next}`)
    }
  }

  return NextResponse.redirect(`${origin}/login?error=Could+not+authenticate`)
}
