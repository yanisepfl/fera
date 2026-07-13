/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // ESLint is run separately; don't fail the production build on lint rules.
  eslint: { ignoreDuringBuilds: true },
  // wagmi/walletconnect/metamask pull optional native deps that must be treated as
  // external / stubbed in web bundling. This keeps `next build` clean.
  webpack: (config) => {
    config.externals.push('pino-pretty', 'lokijs', 'encoding');
    config.resolve = config.resolve || {};
    config.resolve.alias = {
      ...(config.resolve.alias || {}),
      // RN-only optional dep pulled by @metamask/sdk; stub it in the web build.
      '@react-native-async-storage/async-storage': false,
    };
    return config;
  },
};

export default nextConfig;
