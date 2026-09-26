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
			customCss: ['./src/styles/docs.css'],
			lastUpdated: true,
			head: [
				{ tag: 'meta', attrs: { name: 'theme-color', content: '#E8543D' } },
			],
			sidebar: [
				{
					label: 'Getting started',
					items: [
						{ slug: 'getting-started/introduction' },
						{ slug: 'getting-started/install' },
						{ slug: 'getting-started/try-the-demo' },
						{ slug: 'getting-started/connect-a-gateway' },
						{ slug: 'getting-started/tailscale' },
					],
				},
				{
					label: 'Using Pincer',
					items: [
						{ slug: 'guides/organizing-chats' },
						{ slug: 'guides/command-palette-and-navigation' },
						{ slug: 'guides/transcript' },
						{ slug: 'guides/search' },
						{ slug: 'guides/composer' },
						{ slug: 'guides/quick-capture' },
						{ slug: 'guides/shortcuts-and-siri' },
						{ slug: 'guides/sharing-to-pincer' },
						{ slug: 'guides/approvals-and-notifications' },
						{ slug: 'guides/push-notifications' },
						{ slug: 'guides/gateway-settings' },
						{ slug: 'guides/gateway-health' },
						{ slug: 'guides/command-policy' },
						{ slug: 'guides/usage-and-cost' },
						{ slug: 'guides/appearance' },
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
						{ slug: 'development/testflight' },
					],
				},
			],
		}),
	],
});
