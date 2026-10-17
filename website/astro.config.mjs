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
				'A native macOS and iOS app for your OpenClaw Gateway: Quick Capture, Shortcuts, approvals from notifications, offline reading and every gateway in one window.',
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
				{ tag: 'meta', attrs: { name: 'theme-color', content: '#1c1c1e', media: '(prefers-color-scheme: dark)' } },
				{ tag: 'meta', attrs: { name: 'theme-color', content: '#f5f5f7', media: '(prefers-color-scheme: light)' } },
			],
			sidebar: [
				{
					label: 'Getting started',
					items: [
						{ slug: 'getting-started/introduction' },
						{ slug: 'getting-started/why-pincer' },
						{ slug: 'getting-started/install' },
						{ slug: 'getting-started/try-the-demo' },
						{ slug: 'getting-started/connect-a-gateway' },
						{ slug: 'getting-started/setup-wizard' },
						{ slug: 'getting-started/tailscale' },
					],
				},
				{
					label: 'On your Mac and iPhone',
					items: [
						{ slug: 'guides/approvals-and-notifications' },
						{ slug: 'guides/push-notifications', label: 'Notifications while closed (iOS)' },
						{ slug: 'guides/sharing-to-pincer' },
						{ slug: 'guides/shortcuts-and-siri' },
						{ slug: 'guides/deep-links-and-handoff' },
						{ slug: 'guides/quick-capture' },
						{ slug: 'guides/menu-bar' },
						{ slug: 'guides/chat-windows' },
						{ slug: 'guides/command-palette-and-navigation' },
						{ slug: 'guides/offline-outbox' },
						{ slug: 'guides/local-cache' },
					],
				},
				{
					label: 'Chatting',
					items: [
						{ slug: 'guides/organizing-chats' },
						{ slug: 'guides/sessions' },
						{ slug: 'guides/transcript' },
						{ slug: 'guides/search' },
						{ slug: 'guides/export-and-bookmarks' },
						{ slug: 'guides/composer' },
						{ slug: 'guides/edit-regenerate-branch' },
						{ slug: 'guides/tool-calls' },
						{ slug: 'guides/file-diffs' },
						{ slug: 'guides/diagrams-and-math' },
						{ slug: 'guides/read-aloud' },
						{ slug: 'guides/gateway-voice' },
						{ slug: 'guides/subagents-and-runs' },
						{ slug: 'guides/browser-panel' },
						{ slug: 'guides/portals' },
						{ slug: 'guides/appearance' },
						{ slug: 'guides/agent-avatars' },
						{ slug: 'guides/accessibility' },
					],
				},
				{
					label: 'Managing your Gateway',
					items: [
						{ slug: 'guides/gateway-settings' },
						{ slug: 'guides/manage-gateways' },
						{ slug: 'guides/agents' },
						{ slug: 'guides/skills-and-tools' },
						{ slug: 'guides/mcp-servers' },
						{ slug: 'guides/devices' },
						{ slug: 'guides/device-mode' },
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
						{ slug: 'privacy' },
						{ slug: 'support' },
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
