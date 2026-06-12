import { updateSession } from '@/lib/supabase/middleware'
import type { NextRequest } from 'next/server'

export async function middleware(request: NextRequest) {
  return await updateSession(request)
}

export const config = {
  matcher: [
    // Skip Next.js internals, static files, and the public HTML app
    '/((?!_next/static|_next/image|favicon.ico|tutor-hub-app\\.html|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico)$).*)',
  ],
}
