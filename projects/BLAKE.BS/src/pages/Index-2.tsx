import StatCard from "@/components/StatCard";

const Index = () => {
  return (
    <div className="min-h-screen bg-background" style={{ background: 'var(--gradient-dark)' }}>
      {/* Hero Section */}
      <section className="relative overflow-hidden py-20 px-4">
        {/* Background glow effects */}
        <div className="absolute top-1/4 left-1/4 w-96 h-96 bg-primary/20 rounded-full blur-3xl" />
        <div className="absolute bottom-1/4 right-1/4 w-96 h-96 bg-secondary/20 rounded-full blur-3xl" />
        
        <div className="relative z-10 max-w-5xl mx-auto text-center">
          <p className="text-secondary font-semibold uppercase tracking-widest mb-4 animate-pulse-glow">
            🏆 Brawl Stars Legend 🏆
          </p>
          
          <h1 className="font-display text-6xl md:text-8xl lg:text-9xl gradient-text mb-6 animate-float">
            An_Unknown_User
          </h1>
          
          <p className="text-xl md:text-2xl text-foreground/80 max-w-2xl mx-auto mb-8">
            aka <span className="text-accent font-bold">PerfectSoulfulLynx</span> — 
            Dominating the arena with skill, strategy, and style!
          </p>

          <div className="inline-block bg-secondary/20 border border-secondary/40 rounded-full px-6 py-2 text-secondary font-semibold">
            🛡️ Astral Gardians Member
          </div>
        </div>
      </section>

      {/* Stats Section */}
      <section className="py-16 px-4">
        <div className="max-w-5xl mx-auto">
          <h2 className="font-display text-4xl md:text-5xl text-center text-accent text-glow-gold mb-12">
            Insane Stats 🔥
          </h2>
          
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-6">
            <StatCard label="Trophies" value="74,375" icon="🏆" />
            <StatCard label="Brawlers" value="98/98" icon="⭐" />
            <StatCard label="3v3 Wins" value="10,187" icon="🎮" />
            <StatCard label="Total Victories" value="3,223" icon="👑" />
          </div>
          
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-6 mt-6 max-w-2xl mx-auto">
            <StatCard label="Ranked Highest" value="7,138" icon="⚔️" />
            <StatCard label="Win Streak" value="19 MAX" icon="🔥" />
          </div>
        </div>
      </section>

      {/* Favorite Brawler Section */}
      <section className="py-16 px-4">
        <div className="max-w-3xl mx-auto text-center">
          <h2 className="font-display text-4xl md:text-5xl text-foreground mb-6">
            Main Brawler 🎭
          </h2>
          <div className="bg-card rounded-2xl p-8 box-glow-purple border border-secondary/40">
            <p className="text-6xl mb-4">⚔️</p>
            <p className="font-display text-3xl text-secondary mb-2">Admiral Waffles</p>
            <p className="text-muted-foreground">Favorite Brawler • Absolute Beast</p>
          </div>
        </div>
      </section>

      {/* Footer */}
      <footer className="py-12 text-center text-muted-foreground border-t border-border/30">
        <p className="font-display text-3xl text-primary/60 mb-2">
          Fear the Unknown 💀
        </p>
        <p className="text-sm">Tag: #902RLQQ8L</p>
      </footer>
    </div>
  );
};

export default Index;
