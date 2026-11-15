interface Rendered {
  render(width: number): string[];
}

export class FakeScreen {
  readonly terminal = { rows: 40 };
  lines: string[] = [];
  private readonly width: number;
  private readonly components = new Set<Rendered>();

  constructor(width = 120) {
    this.width = width;
  }

  show(component: Rendered): void {
    this.components.add(component);
    this.requestRender();
  }

  hide(component: Rendered): void {
    this.components.delete(component);
    this.requestRender();
  }

  requestRender(): void {
    this.lines = [...this.components].flatMap((component) =>
      component.render(this.width),
    );
  }
}
