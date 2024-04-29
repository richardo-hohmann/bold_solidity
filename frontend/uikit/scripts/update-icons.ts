import { transform } from "@svgr/core";
import { readFile, writeFile } from "node:fs/promises";
import { join as pathJoin, parse as pathParse } from "node:path";
import { $, argv, echo, glob } from "zx";

const HELP = `
Optimizes and converts the SVG icons found in src/icons/svg/ into components.

Usage:
  pnpm tsx update-icons.ts

Options:
  --help, -h  Show this help message.
`;

export async function main() {
  const options = {
    help: "help" in argv || "h" in argv,
  };

  if (options.help) {
    echo`${HELP}`;
    process.exit(0);
  }

  const icons = await glob(
    pathJoin(import.meta.dirname, "../src/icons/svg/*.svg"),
  );

  const components = await Promise.all(
    icons.map(async (path) => {
      const svg = await readFile(path, "utf8");
      const { name } = pathParse(path);
      const componentName = `Icon${kebabToPascal(name)}`;
      const transformed = await transform(svg, {
        plugins: ["@svgr/plugin-svgo", "@svgr/plugin-jsx"],
        icon: 24,
        typescript: true,
        template: svgrTemplate,
        jsxRuntime: "automatic",
        exportType: "named",
        expandProps: false,
        replaceAttrValues: {
          "#000": "currentColor",
          "#000000": "currentColor",
        },
        svgoConfig: {
          plugins: [
            "removeUselessDefs",
            "removeXMLNS",
            "cleanupIds",
          ],
        },
      }, {
        componentName,
      });

      await writeFile(
        pathJoin(import.meta.dirname, `../src/icons/${componentName}.tsx`),
        "// this file was generated by scripts/update-icons.ts\n"
          + "// please do not edit it manually\n\n"
          + await format(transformed),
      );

      return { name, componentName };
    }),
  );

  await writeFile(
    pathJoin(import.meta.dirname, `../src/icons/index.ts`),
    "// this file was generated by scripts/update-icons.ts\n"
      + "// please do not edit it manually\n\n"
      + await format(
        components
          .map(({ componentName }) => `export { ${componentName} } from "./${componentName}";`)
          .join("\n"),
      ),
  );

  console.log(`\nGenerated ${components.length} icon components:\n`);
  console.log(
    components.map(({ name, componentName }) => (
      `src/icons/${componentName}.tsx (${name}.svg)`
    )).join("\n"),
  );
  console.log("\nIndex file updated: src/icons/index.ts\n");
}

type Template = NonNullable<
  NonNullable<Parameters<typeof transform>[1]>["template"]
>;

const svgrTemplate: Template = function template(...[variables, { tpl }]) {
  return tpl`
// this file was generated by scripts/update-icons.ts
// please do not edit it manually
${variables.interfaces};

${variables.imports};

export function ${variables.componentName} (${variables.props}) {
  return ${variables.jsx};
}
`;
};

async function format(content: string) {
  const dprint = $`dprint fmt --stdin tsx`.quiet();
  dprint.stdin.write(content);
  dprint.stdin.end();
  const { stdout } = await dprint;
  return stdout;
}

// kebab case (e.g. arrow-left) => Pascal case (e.g. ArrowLeft)
function kebabToPascal(str: string) {
  return str
    .split("-")
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join("");
}

main();
