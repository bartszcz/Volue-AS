import type { Metadata, Viewport } from "next";
import { Roboto, Roboto_Mono } from "next/font/google";
import { ThemeProvider } from "next-themes";
import MsalProviderWrapper from "@/components/auth/msal-provider-wrapper";
import { I18nProvider } from "@/lib/i18n";
import "./globals.css";

const roboto = Roboto({
  subsets: ["latin"],
  weight: ["300", "400", "700"],
  variable: "--font-sans",
});

const robotoMono = Roboto_Mono({
  subsets: ["latin"],
  variable: "--font-mono",
});

export const metadata: Metadata = {
  title: "HSE Newsletter Manager",
  description:
    "Manage and schedule HSE safety bulletin newsletters for your organization. Upload, preview, reorder, and sync to OneDrive for automated email delivery.",
  icons: {
    icon: [
      {
        url: "/icon-light-32x32.png",
        media: "(prefers-color-scheme: light)",
      },
      {
        url: "/icon-dark-32x32.png",
        media: "(prefers-color-scheme: dark)",
      },
      {
        url: "/icon.svg",
        type: "image/svg+xml",
      },
    ],
    apple: "/apple-icon.png",
  },
};

export const viewport: Viewport = {
  themeColor: [
    { media: "(prefers-color-scheme: light)", color: "#00765a" },
    { media: "(prefers-color-scheme: dark)", color: "#004340" },
  ],
  width: "device-width",
  initialScale: 1,
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" suppressHydrationWarning className={`${roboto.variable} ${robotoMono.variable}`}>
      <body className="font-sans antialiased">
        <ThemeProvider
          attribute="class"
          defaultTheme="system"
          enableSystem
          disableTransitionOnChange
        >
          <I18nProvider>
            <MsalProviderWrapper>{children}</MsalProviderWrapper>
          </I18nProvider>
        </ThemeProvider>
      </body>
    </html>
  );
}
