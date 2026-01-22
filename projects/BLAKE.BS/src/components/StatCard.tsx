interface StatCardProps {
  label: string;
  value: string;
  icon?: string;
}

const StatCard = ({ label, value, icon }: StatCardProps) => {
  return (
    <div className="bg-card rounded-xl p-6 box-glow-cyan border border-primary/30 hover:border-primary/60 transition-all duration-300 hover:scale-105">
      <div className="text-muted-foreground text-sm uppercase tracking-wider mb-2">
        {icon && <span className="mr-2">{icon}</span>}
        {label}
      </div>
      <div className="font-display text-3xl md:text-4xl text-primary text-glow-cyan">
        {value}
      </div>
    </div>
  );
};

export default StatCard;
