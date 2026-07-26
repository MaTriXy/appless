package dev.appless.openuilang

import java.io.File
import java.nio.charset.StandardCharsets
import java.nio.file.Path

/**
 * The GenOS component contract, loaded from `spec/contract/genos.schema.json`
 * (spec/openui-lang.md §8.3 required/optional props of the GenOS contract).
 *
 * Mirrors `LibrarySchema.swift`. Provides everything the parser needs from the
 * contract:
 * - [root]: the library's root component type name (e.g. `"Card"`).
 * - [components]: every known component type name.
 * - [paramOrder]: for each component, the positional-argument order and
 *   requiredness (the schema body's `properties` are alphabetized for diff
 *   stability, so positional order is carried separately by the contract).
 * - [schema]: the raw JSON Schema body (`$defs` etc.) for validation rules.
 */
public class LibrarySchema(
    public val root: String,
    public val components: List<String>,
    public val paramOrder: Map<String, List<Param>>,
    public val schema: JsonValue,
) {
    public data class Param(
        val name: String,
        val required: Boolean,
        /**
         * The JSON Schema `default` for this property, if any
         * (`$defs.<Component>.properties.<name>.default`). lang-core's
         * `compileSchema` carries it as `defaultValue` and `materializeValue`
         * applies it to a missing/null REQUIRED prop before reporting
         * missing-required/null-required (parser.js `getSchemaDefaultValue`).
         */
        val defaultValue: JsonValue? = null,
    )

    public class LoadException(detail: String) :
        RuntimeException("malformed contract schema: $detail")

    public companion object {
        /** Loads the contract from a `genos.schema.json` file. */
        public fun load(file: File): LibrarySchema =
            parse(file.readText(StandardCharsets.UTF_8))

        /** Loads the contract from a `genos.schema.json` path. */
        public fun load(path: Path): LibrarySchema = load(path.toFile())

        /** Loads the contract from a `genos.schema.json` path string. */
        public fun load(path: String): LibrarySchema = load(File(path))

        public fun parse(text: String): LibrarySchema {
            val doc = JsonValue.parse(text)

            val root = doc["root"]?.stringValue
                ?: throw LoadException("missing string \"root\"")
            val componentValues = doc["components"]?.arrayValue
                ?: throw LoadException("missing array \"components\"")
            val components = componentValues.map {
                it.stringValue ?: throw LoadException("non-string entry in \"components\"")
            }
            val paramOrderObject = doc["paramOrder"]?.objectValue
                ?: throw LoadException("missing object \"paramOrder\"")
            val schema = doc["schema"]
            if (schema == null || schema.objectValue == null) {
                throw LoadException("missing object \"schema\"")
            }

            val paramOrder = LinkedHashMap<String, List<Param>>()
            for ((component, value) in paramOrderObject) {
                val entries = value.arrayValue
                    ?: throw LoadException("paramOrder[$component] is not an array")
                val properties = schema["\$defs"]?.get(component)?.get("properties")
                paramOrder[component] = entries.map { entry ->
                    val name = entry["name"]?.stringValue
                    val required = entry["required"]?.boolValue
                    if (name == null || required == null) {
                        throw LoadException("paramOrder[$component] entry missing name/required")
                    }
                    // parser.js `getSchemaDefaultValue`: the property's
                    // `default`, when the property is a (non-array) object.
                    val property = properties?.get(name)
                    val defaultValue =
                        if (property?.objectValue != null) property["default"] else null
                    Param(name = name, required = required, defaultValue = defaultValue)
                }
            }

            return LibrarySchema(
                root = root,
                components = components,
                paramOrder = paramOrder,
                schema = schema,
            )
        }
    }
}
