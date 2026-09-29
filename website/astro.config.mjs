// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// Hosted on Vercel at the domain root. SITE_URL sets the canonical URL (e.g. a custom domain).
const site =
	process.env.SITE_URL ??
	(process.env.VERCEL_PROJECT_PRODUCTION_URL
		? `https://${process.env.VERCEL_PROJECT_PRODUCTION_URL}`
		: 'http://localhost:4321');
const base = process.env.SITE_BASE ?? '/';

export default defineConfig({
	site,
	base,
	trailingSlash: 'always',
	integrations: [
		starlight({
			title: 'Pincer',
			description:
				'A native macOS and iOS client for OpenClaw. Organized chats, live thinking, tool calls and inline images.',
			logo: { src: './src/assets/logo.svg', alt: 'Pincer' },
			favicon: '/favicon.svg',
			social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/hartra344/pincer' }],
			editLink: { baseUrl: 'https://github.com/hartra344/pincer/edit/main/website/' },
			customCss: ['./src/styles/tokens.css', './src/styles/docs.css'],
			components: {
				SocialIcons: './src/components/starlight/SocialIcons.astro',
				Footer: './src/components/starlight/Footer.astro',
			},
			lastUpdated: true,
			head: [
				{ tag: 'meta', attrs: { name: 'theme-color', content: '#1f2b27', media: '(prefers-color-scheme: dark)' } },
				{ tag: 'meta', attrs: { name: 'theme-color', content: '#d6dfda', media: '(prefers-color-scheme: light)' } },
			],
			sidebar: [
				{
					label: 'Getting started',
					items: [
						{ slug: 'getting-started/introduction' },
						{ slug: 'getting-started/install' },
						{ slug: 'getting-started/try-the-demo' },
						{ slug: 'getting-started/connect-a-gateway' },
						{ slug: 'getting-started/setup-wizard' },
						{ slug: 'getting-started/tailscale' },
					],
				},
				{
					label: 'Using Pincer',
					items: [
						{ slug: 'guides/organizing-chats' },
						{ slug: 'guides/sessions' },
						{ slug: 'guides/command-palette-and-navigation' },
						{ slug: 'guides/chat-windows' },
						{ slug: 'guides/transcript' },
						{ slug: 'guides/search' },
						{ slug: 'guides/export-and-bookmarks' },
						{ slug: 'guides/composer' },
						{ slug: 'guides/tool-calls' },
						{ slug: 'guides/file-diffs' },
						{ slug: 'guides/diagrams-and-math' },
						{ slug: 'guides/subagents-and-runs' },
						{ slug: 'guides/quick-capture' },
						{ slug: 'guides/menu-bar' },
						{ slug: 'guides/shortcuts-and-siri' },
						{ slug: 'guides/deep-links-and-handoff' },
						{ slug: 'guides/sharing-to-pincer' },
						{ slug: 'guides/approvals-and-notifications' },
						{ slug: 'guides/push-notifications', label: 'Notifications while closed (iOS)' },
						{ slug: 'guides/offline-outbox' },
						{ slug: 'guides/local-cache' },
						{ slug: 'guides/appearance' },
						{ slug: 'guides/agent-avatars' },
						{ slug: 'guides/accessibility' },
					],
				},
				{
					label: 'Managing your Gateway',
					items: [
						{ slug: 'guides/gateway-settings' },
						{ slug: 'guides/agents' },
						{ slug: 'guides/skills-and-tools' },
						{ slug: 'guides/mcp-servers' },
						{ slug: 'guides/devices' },
						{ slug: 'guides/command-policy' },
						{ slug: 'guides/gateway-health' },
						{ slug: 'guides/channel-status' },
						{ slug: 'guides/gateway-logs' },
						{ slug: 'guides/usage-and-cost' },
					],
				},
				{
					label: 'Reference',
					items: [
						{ slug: 'reference/security' },
						{ slug: 'reference/keyboard-shortcuts' },
						{ slug: 'reference/synced-preferences' },
						{ slug: 'reference/troubleshooting' },
					],
				},
				{
					label: 'Development',
					collapsed: true,
					items: [
						{ slug: 'development/building' },
						{ slug: 'development/mock-gateway' },
						{ slug: 'development/contributing' },
						{ slug: 'development/testflight' },
						{ slug: 'development/localization' },
					],
				},
			],
		}),
	],
});
