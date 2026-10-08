#!/usr/bin/env python3
"""
Build Resources/Translate.shortcut: the Shortcut the System Translate action
runs when a language pair is not downloaded (SystemTranslator.viaShortcut).

What the Shortcut does: take "text=…&to=zh_CN&from=es_ES" as its input (`from`
is optional), hand the three values to the "Translate Text" step, output the
translation.

A Shortcut file can only be imported when Apple has signed it, so the last step
runs `shortcuts sign --mode anyone`. That needs a network connection, and it
uploads the Shortcut (which holds nothing private) to iCloud as a public shared
record: the signing certificate's common name is that record's id, readable at
https://www.icloud.com/shortcuts/api/records/<id>. It was run on a Mac signed
in to iCloud; whether it works on one that is not has not been tried.

The signed file is committed, so a build — CI included — only copies it into
the app and never signs anything itself.

The signature's certificate lasts about 13 months. Whether macOS refuses an
import after that is not known. `--check` warns when fewer than 90 days are
left; every build runs it. `--check --strict` also fails when fewer than 30 are
left; a weekly workflow runs that, so a build is never blocked by the date.
Either way: re-run this script and commit the new file.

Usage: scripts/make-translate-shortcut.py                   build and sign
       scripts/make-translate-shortcut.py --check [--strict] verify the committed file
"""
import datetime
import os
import plistlib
import struct
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Resources", "Translate.shortcut")

DICT_VALUE = ("A1000000-0000-4000-8000-000000000001",
              "A1000000-0000-4000-8000-000000000002",
              "A1000000-0000-4000-8000-000000000003")
TRANSLATED = "A1000000-0000-4000-8000-000000000004"


def attachment(value):
    return {"Value": value, "WFSerializationType": "WFTextTokenAttachment"}


def text_token(value):
    return {"Value": {"string": "￼", "attachmentsByRange": {"{0, 1}": value}},
            "WFSerializationType": "WFTextTokenString"}


def variable(name):
    return {"VariableName": name, "Type": "Variable"}


def action(identifier, **parameters):
    return {"WFWorkflowActionIdentifier": "is.workflow.actions." + identifier,
            "WFWorkflowActionParameters": parameters}


def read_key(key, uuid):
    """dict[key] → a variable named after the key."""
    return [
        action("getvalueforkey", WFInput=attachment(variable("dict")), WFDictionaryKey=key, UUID=uuid),
        action("setvariable", WFVariableName=key,
               WFInput=attachment({"OutputUUID": uuid, "Type": "ActionOutput",
                                   "OutputName": "Dictionary Value"})),
    ]


actions = [
    action("comment", WFCommentActionText=(
        "Installed from an app's System Translate action, which runs it to translate "
        "a language that is not downloaded. Please do not rename or edit it.\n"
        "Input: text=…&to=zh_CN&from=es_ES (from is optional).")),
    # The input text reads as a query string, which Shortcuts turns into a dictionary.
    action("setvariable", WFVariableName="dict", WFInput=attachment({"Type": "ExtensionInput"})),
    *read_key("text", DICT_VALUE[0]),
    *read_key("from", DICT_VALUE[1]),
    *read_key("to", DICT_VALUE[2]),
    action("text.translate", UUID=TRANSLATED,
           WFInputText=text_token(variable("text")),
           WFSelectedFromLanguage=attachment(variable("from")),
           WFSelectedLanguage=attachment(variable("to"))),
    action("output", WFOutput=text_token({"OutputUUID": TRANSLATED, "Type": "ActionOutput",
                                          "OutputName": "Translated Text"})),
]

workflow = {
    "WFWorkflowMinimumClientVersion": 1113,
    "WFWorkflowMinimumClientVersionString": "1113",
    "WFWorkflowClientVersion": "1146.14",
    "WFWorkflowIcon": {"WFWorkflowIconStartColor": -2873601, "WFWorkflowIconGlyphNumber": 61440},
    "WFWorkflowActions": actions,
    "WFWorkflowInputContentItemClasses": ["WFStringContentItem"],
    "WFWorkflowOutputContentItemClasses": ["WFStringContentItem"],
    "WFWorkflowHasOutputFallback": False,
    "WFWorkflowHasShortcutInputVariables": True,
    "WFWorkflowImportQuestions": [],
    "WFQuickActionSurfaces": [],
    "WFWorkflowTypes": [],
}


def signature_end():
    """The end date of the signing certificate in the signed file: an Apple
    Encrypted Archive, whose header carries the certificate chain as a plist."""
    with open(OUT, "rb") as f:
        data = f.read()
    if data[:4] != b"AEA1":
        sys.exit(f"{OUT} is not a signed Shortcut")
    size = struct.unpack("<I", data[8:12])[0]
    leaf = plistlib.loads(data[12:12 + size])["SigningCertificateChain"][0]
    out = subprocess.run(["/usr/bin/openssl", "x509", "-inform", "der", "-noout", "-enddate"],
                         input=leaf, capture_output=True).stdout.decode().strip()
    # "notAfter=Nov  2 19:50:26 2027 GMT"
    return datetime.datetime.strptime(out.split("=", 1)[1], "%b %d %H:%M:%S %Y %Z").replace(
        tzinfo=datetime.timezone.utc)


def check(strict):
    end = signature_end()
    days = (end - datetime.datetime.now(datetime.timezone.utc)).days
    message = (f"Resources/Translate.shortcut: its signature ends {end:%Y-%m-%d} ({days} days left). "
               "Re-run scripts/make-translate-shortcut.py and commit the result.")
    if strict and days < 30:
        sys.exit("::error::" + message)
    if days < 90:
        print("::warning::" + message)
    else:
        print(f"Resources/Translate.shortcut: signed, {days} days left")


def build():
    with tempfile.TemporaryDirectory() as tmp:
        unsigned = os.path.join(tmp, "Translate.shortcut")
        with open(unsigned, "wb") as f:
            plistlib.dump(workflow, f, fmt=plistlib.FMT_BINARY)
        result = subprocess.run(["/usr/bin/shortcuts", "sign", "--mode", "anyone",
                                 "--input", unsigned, "--output", OUT],
                                capture_output=True, text=True)
        if result.returncode != 0 or not os.path.exists(OUT):
            sys.exit("shortcuts sign failed: " + (result.stderr or result.stdout).strip())
    print(f"wrote {os.path.relpath(OUT, ROOT)}; signature ends {signature_end():%Y-%m-%d}")


if __name__ == "__main__":
    if sys.argv[1:] in (["--check"], ["--check", "--strict"]):
        check(strict="--strict" in sys.argv)
    elif sys.argv[1:]:
        sys.exit(__doc__)
    else:
        build()
