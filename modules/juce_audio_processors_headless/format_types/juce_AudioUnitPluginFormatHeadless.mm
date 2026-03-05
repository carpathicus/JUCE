/*
  ==============================================================================

   This file is part of the JUCE framework.
   Copyright (c) Raw Material Software Limited

   JUCE is an open source framework subject to commercial or open source
   licensing.

   By downloading, installing, or using the JUCE framework, or combining the
   JUCE framework with any other source code, object code, content or any other
   copyrightable work, you agree to the terms of the JUCE End User Licence
   Agreement, and all incorporated terms including the JUCE Privacy Policy and
   the JUCE Website Terms of Service, as applicable, which will bind you. If you
   do not agree to the terms of these agreements, we will not license the JUCE
   framework to you, and you must discontinue the installation or download
   process and cease use of the JUCE framework.

   JUCE End User Licence Agreement: https://juce.com/legal/juce-8-licence/
   JUCE Privacy Policy: https://juce.com/juce-privacy-policy
   JUCE Website Terms of Service: https://juce.com/juce-website-terms-of-service/

   Or:

   You may also use this code under the terms of the AGPLv3:
   https://www.gnu.org/licenses/agpl-3.0.en.html

   THE JUCE FRAMEWORK IS PROVIDED "AS IS" WITHOUT ANY WARRANTY, AND ALL
   WARRANTIES, WHETHER EXPRESSED OR IMPLIED, INCLUDING WARRANTY OF
   MERCHANTABILITY OR FITNESS FOR A PARTICULAR PURPOSE, ARE DISCLAIMED.

  ==============================================================================
*/

#if JUCE_INTERNAL_HAS_AU

#include <juce_audio_processors_headless/format_types/juce_AudioUnitPluginFormatImpl.h>

namespace juce
{

void AudioUnitPluginFormatHeadless::findAllTypesForFile (OwnedArray<PluginDescription>& results,
                                                         const String& fileOrIdentifier)
{
    if (! fileMightContainThisPluginType (fileOrIdentifier))
        return;

    // ---------------------------------------------------------------
    // Lightweight scan: query the AudioComponent registry for metadata
    // WITHOUT instantiating the plugin.  This mirrors what Logic Pro
    // does and avoids crashes / freezes from misbehaving plugin code.
    // ---------------------------------------------------------------

    AudioComponentDescription componentDesc;
    String pluginName, version, manufacturer;

    if (! AudioUnitFormatHelpers::getComponentDescFromIdentifier (fileOrIdentifier, componentDesc,
                                                                  pluginName, version, manufacturer)
        && ! AudioUnitFormatHelpers::getComponentDescFromFile (fileOrIdentifier, componentDesc,
                                                               pluginName, version, manufacturer))
    {
        return;
    }

    AudioComponent auComp = AudioComponentFindNext (nullptr, &componentDesc);
    if (auComp == nullptr)
        return;

    // Re-read name / manufacturer in case getComponentDescFromFile was used
    if (pluginName.isEmpty() || manufacturer.isEmpty())
        AudioUnitFormatHelpers::getNameAndManufacturer (auComp, pluginName, manufacturer);

    // Version (if not yet populated)
    if (version.isEmpty())
    {
        UInt32 versionNum = 0;
        if (AudioComponentGetVersion (auComp, &versionNum) == noErr)
        {
            version << (int) (versionNum >> 16) << "."
                    << (int) ((versionNum >> 8) & 0xff) << "."
                    << (int) (versionNum & 0xff);
        }
    }

    auto* desc = new PluginDescription();
    desc->name                = pluginName;
    desc->descriptiveName     = pluginName;
    desc->fileOrIdentifier    = AudioUnitFormatHelpers::createPluginIdentifier (componentDesc);
    desc->uniqueId = desc->deprecatedUid
        = ((int) componentDesc.componentType)
        ^ ((int) componentDesc.componentSubType)
        ^ ((int) componentDesc.componentManufacturer);
    desc->lastFileModTime     = Time();
    desc->lastInfoUpdateTime  = Time::getCurrentTime();
    desc->pluginFormatName    = "AudioUnit";
    desc->category            = AudioUnitFormatHelpers::getCategory (componentDesc.componentType);
    desc->manufacturerName    = manufacturer;
    desc->version             = version;
    desc->isInstrument        = (componentDesc.componentType == kAudioUnitType_MusicDevice);

    // Channel counts are unknown without instantiation; they will be
    // determined when the plugin is actually loaded for use.
    desc->numInputChannels    = 0;
    desc->numOutputChannels   = 0;

    results.add (desc);
}

void AudioUnitPluginFormatHeadless::createPluginInstance (const PluginDescription& desc,
                                                          double rate,
                                                          int blockSize,
                                                          PluginCreationCallback callback)
{
    createAudioUnitPluginInstance<AudioUnitPluginInstanceHeadless> (*this, desc, rate, blockSize, callback);
}

void AudioUnitPluginFormatHeadless::createARAFactoryAsync (const PluginDescription& desc, ARAFactoryCreationCallback callback)
{
    auto auComponentResult = getAudioComponent (*this, desc);

    if (! auComponentResult.isValid())
    {
        callback ({ {}, "Failed to create AudioComponent for " + desc.descriptiveName });
        return;
    }

    getOrCreateARAAudioUnit (auComponentResult.component, [cb = std::move (callback)] (auto dylibKeepAliveAudioUnit)
    {
        cb ([&]() -> ARAFactoryResult
            {
                if (dylibKeepAliveAudioUnit != nullptr)
                    return { ARAFactoryWrapper { ::juce::getARAFactory (std::move (dylibKeepAliveAudioUnit)) }, "" };

                return { {}, "Failed to create ARAFactory from the provided AudioUnit" };
            }());
    });
}

bool AudioUnitPluginFormatHeadless::requiresUnblockedMessageThreadDuringCreation (const PluginDescription& desc) const
{
    String pluginName, version, manufacturer;
    AudioComponentDescription componentDesc;

    if (AudioUnitFormatHelpers::getComponentDescFromIdentifier (desc.fileOrIdentifier, componentDesc,
                                                                pluginName, version, manufacturer)
           || AudioUnitFormatHelpers::getComponentDescFromFile (desc.fileOrIdentifier, componentDesc,
                                                                pluginName, version, manufacturer))
    {
        if (AudioComponent auComp = AudioComponentFindNext (nullptr, &componentDesc))
        {
            if (AudioComponentGetDescription (auComp, &componentDesc) == noErr)
                return AudioUnitFormatHelpers::isPluginAUv3 (componentDesc);
        }
    }

    return false;
}

StringArray AudioUnitPluginFormatHeadless::searchPathsForPlugins (const FileSearchPath&, bool /*recursive*/, bool allowPluginsWhichRequireAsynchronousInstantiation)
{
    StringArray result;
    AudioComponent comp = nullptr;

    for (;;)
    {
        AudioComponentDescription desc;
        zerostruct (desc);

        comp = AudioComponentFindNext (comp, &desc);

        if (comp == nullptr)
            break;

        if (AudioComponentGetDescription (comp, &desc) != noErr)
            continue;

        if (desc.componentType == kAudioUnitType_MusicDevice
             || desc.componentType == kAudioUnitType_MusicEffect
             || desc.componentType == kAudioUnitType_Effect
             || desc.componentType == kAudioUnitType_Generator
             || desc.componentType == kAudioUnitType_Panner
             || desc.componentType == kAudioUnitType_Mixer
             || desc.componentType == kAudioUnitType_MIDIProcessor)
        {
            if (allowPluginsWhichRequireAsynchronousInstantiation || ! AudioUnitFormatHelpers::isPluginAUv3 (desc))
                result.add (AudioUnitFormatHelpers::createPluginIdentifier (desc));
        }
    }

    return result;
}

bool AudioUnitPluginFormatHeadless::fileMightContainThisPluginType (const String& fileOrIdentifier)
{
    AudioComponentDescription desc;
    String name, version, manufacturer;

    if (AudioUnitFormatHelpers::getComponentDescFromIdentifier (fileOrIdentifier, desc, name, version, manufacturer))
        return AudioComponentFindNext (nullptr, &desc) != nullptr;

    auto f = File::createFileWithoutCheckingPath (fileOrIdentifier);

    return (f.hasFileExtension (".component") || f.hasFileExtension (".appex"))
             && f.isDirectory();
}

String AudioUnitPluginFormatHeadless::getNameOfPluginFromIdentifier (const String& fileOrIdentifier)
{
    AudioComponentDescription desc;
    String name, version, manufacturer;
    AudioUnitFormatHelpers::getComponentDescFromIdentifier (fileOrIdentifier, desc, name, version, manufacturer);

    if (name.isEmpty())
        name = fileOrIdentifier;

    return name;
}

bool AudioUnitPluginFormatHeadless::pluginNeedsRescanning (const PluginDescription& desc)
{
    AudioComponentDescription newDesc;
    String name, version, manufacturer;

    return ! (AudioUnitFormatHelpers::getComponentDescFromIdentifier (desc.fileOrIdentifier, newDesc,
                                                                      name, version, manufacturer)
               && version == desc.version);
}

bool AudioUnitPluginFormatHeadless::doesPluginStillExist (const PluginDescription& desc)
{
    if (desc.fileOrIdentifier.startsWithIgnoreCase (AudioUnitFormatHelpers::auIdentifierPrefix))
        return fileMightContainThisPluginType (desc.fileOrIdentifier);

    return File (desc.fileOrIdentifier).exists();
}

FileSearchPath AudioUnitPluginFormatHeadless::getDefaultLocationsToSearch()
{
    return {};
}

} // namespace juce

#endif
