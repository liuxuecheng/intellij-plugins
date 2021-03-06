package com.intellij.flex.uiDesigner.mxml {
import com.intellij.flex.uiDesigner.ClassPool;
import com.intellij.flex.uiDesigner.DocumentFactory;
import com.intellij.flex.uiDesigner.DocumentFactoryManager;
import com.intellij.flex.uiDesigner.EmbedImageManager;
import com.intellij.flex.uiDesigner.EmbedSwfManager;
import com.intellij.flex.uiDesigner.Module;
import com.intellij.flex.uiDesigner.UncaughtErrorManager;
import com.intellij.flex.uiDesigner.css.CssEmbedImageDeclaration;
import com.intellij.flex.uiDesigner.css.CssEmbedSwfDeclaration;
import com.intellij.flex.uiDesigner.css.CssSkinClassDeclaration;
import com.intellij.flex.uiDesigner.flex.DeferredInstanceFromBytesContextImpl;
import com.intellij.flex.uiDesigner.io.Amf3Types;
import com.intellij.flex.uiDesigner.io.AmfExtendedTypes;
import com.intellij.flex.uiDesigner.libraries.FlexLibrarySet;

import flash.display.DisplayObjectContainer;
import flash.utils.ByteArray;
import flash.utils.IDataInput;
import flash.utils.Proxy;

public class MxmlReader implements DocumentReader {
  protected var input:IDataInput;
  
  internal var stringRegistry:StringRegistry;

  private const stateReader:StateReader = new StateReader();
  //noinspection JSFieldCanBeLocal
  private const injectedASReader:InjectedASReader = new InjectedASReader(this as MxmlReader);

  protected var module:Module;
  internal var context:DocumentReaderContext;
  private var styleManager:StyleManagerEx;

  internal var objectTable:Vector.<Object>;
  
  internal var factoryContext:DeferredInstanceFromBytesContext;

  protected var rootObject:Object;

  private const deferredSetStyleProxyPool:Vector.<DeferredSetStyleProxy> = new Vector.<DeferredSetStyleProxy>();

  public function MxmlReader() {
    stringRegistry = StringRegistry.instance;
  }

  private function createDeferredSetStyleProxy():DeferredSetStyleProxy {
    var deferredSetStyleProxy:DeferredSetStyleProxy;
    if (deferredSetStyleProxyPool.length == 0) {
      deferredSetStyleProxy = new DeferredSetStyleProxy();
    }
    else {
      deferredSetStyleProxy = deferredSetStyleProxyPool.pop();
    }

    deferredSetStyleProxy.file = context.file;
    return deferredSetStyleProxy;
  }

  public function read(input:IDataInput, context:DocumentReaderContext, styleManager:StyleManagerEx):Object {
    this.styleManager = styleManager;
    this.input = input;
    var component:Object = doRead(context, true);
    stateReader.read(this, input, component);
    injectedASReader.readBinding(input);
    stateReader.reset(factoryContext);

    if (input is ByteArray) {
      assert(input.bytesAvailable == 0);
      ByteArray(input).position = 0;
    }

    return component;
  }

  public function readDeferredInstanceFromBytes(input:IDataInput, factoryContext:DeferredInstanceFromBytesContext):Object {
    this.input = input;
    var object:Object = doRead(factoryContext.readerContext, false);
    assert(this.factoryContext == null);
    if (input is ByteArray) {
      assert(input.bytesAvailable == 0);
      ByteArray(input).position = 0;
    }
    return object;
  }

  private function doRead(context:DocumentReaderContext, isDocumentLevel:Boolean):Object {
    this.context = context;
    module = Module(context.moduleContext);

    const objectTableSize:int = input.readUnsignedShort();
    if (objectTableSize != 0) {
      objectTable = new Vector.<Object>(objectTableSize, true);
    }

    if (isDocumentLevel) {
      injectedASReader.readDeclarations(input);
    }

    var object:Object;
    switch (input.readByte()) {
      case Amf3Types.OBJECT:
        const fqn:String = stringRegistry.readNotNull(input);
        object = context.instanceForRead || new (module.getClass(fqn))();
        break;

      case AmfExtendedTypes.DOCUMENT_REFERENCE:
        object = readDocumentFactory().newInstance();
        break;

      default:
        throw new ArgumentError("unknown property type");
    }

    beforeReadRootObjectProperties(object, isDocumentLevel);
    return readObjectProperties(object);
  }

  protected function beforeReadRootObjectProperties(object:Object, isDocumentLevel:Boolean):void {
  }

  // must be called after readDeferredInstanceFromBytes().
  // readDeferredInstanceFromBytes() — for DeferredInstanceFromBytes — if we have static objects in our deferred parent,
  // we may need refer to it — as example, DESTINATION for other dynamic (i. e., included/excluded from some state) parent child (AFTER, as example)
  // or state-specific properties:
  // <VGroup includeIn="A, B">
  //   <Label text.A="A" text.B="B"/>
  // </VGroup>
  public function getObjectTableForDeferredInstanceFromBytes():Vector.<Object> {
    return objectTable;
  }
  
  internal function readObjectReference():Object {
    var o:Object;
    if ((o = objectTable[AmfUtil.readUInt29(input)]) == null) {
      throw new ArgumentError("must be not null");
    }

    return o;
  }

  internal function readMxmlObjectFromClass(className:String, parent:Object = null):Object {
    return readObjectProperties(new (module.getClass(className))(), parent);
  }

  private function readObjectProperties(object:Object, parent:Object = null):Object {
    const reference:int = input.readUnsignedShort();
    var propertyName:String = stringRegistry.read(input);
    var objectDeclarationRangeMarkerId:int;
    if (propertyName == "$fud_r") {
      objectDeclarationRangeMarkerId = AmfUtil.readUInt29(input);
      context.registerComponentDeclarationRangeMarkerId(object, objectDeclarationRangeMarkerId);
      propertyName = stringRegistry.read(input);
    }

    return initObject(object, reference, propertyName, objectDeclarationRangeMarkerId, parent);
  }

  protected function registerEffect(propertyName:String, object:Object):void {

  }

  private function initObject(object:Object, reference:int, propertyName:String, objectDeclarationTextOffset:int, parent:Object):Object {
    processReference(reference, object);
    var deferredSetStyleProxy:DeferredSetStyleProxy;
    var explicitInlineCssRulesetCreated:Boolean;
    if (!(object is Proxy) && "deferredSetStyles" in object) {
      deferredSetStyleProxy = createDeferredSetStyleProxy();
      deferredSetStyleProxy.objectDeclarationTextOffset = objectDeclarationTextOffset;
      object.deferredSetStyles = deferredSetStyleProxy;
    }

    var propertyHolder:Object = object;
    var cssDeclaration:CssDeclarationImpl;
    var marker:int;
    //noinspection AssignmentToFunctionParameterJS
    for (; propertyName != null; propertyName = stringRegistry.read(input)) {
      marker = input.readByte();
      const isStyle:Boolean = marker == AmfExtendedTypes.STYLE;
      if (isStyle) {
        if (deferredSetStyleProxy.inlineCssRuleset == null) {
          explicitInlineCssRulesetCreated = true;
          deferredSetStyleProxy.inlineCssRuleset = InlineCssRuleset.createInline(AmfUtil.readUInt29(input), AmfUtil.readUInt29(input),
                                                                                 context.file);
        }
        else if (!explicitInlineCssRulesetCreated) {
          explicitInlineCssRulesetCreated = true;
          // skip line and text offset
          AmfUtil.readUInt29(input);
          AmfUtil.readUInt29(input);
        }

        //noinspection JSMismatchedCollectionQueryUpdate
        var cssDeclarations:Vector.<CssDeclaration> = deferredSetStyleProxy.inlineCssRuleset.declarations;
        const flags:int = input.readUnsignedByte();
        if ((flags & StyleFlags.SKIN_IN_PROJECT) != 0) {
          cssDeclarations[cssDeclarations.length] = new CssSkinClassDeclaration(readDocumentFactory(), CssRuleset.GUESS_TEXT_OFFSET_BY_PARENT);
          continue;
        }
        else if ((flags & StyleFlags.EMBED_IMAGE) != 0) {
          cssDeclarations[cssDeclarations.length] = CssEmbedImageDeclaration.create(propertyName, CssRuleset.GUESS_TEXT_OFFSET_BY_PARENT, AmfUtil.readUInt29(input));
          continue;
        }
        else if ((flags & StyleFlags.EMBED_SWF) != 0) {
          cssDeclarations[cssDeclarations.length] = CssEmbedSwfDeclaration.create2(propertyName, CssRuleset.GUESS_TEXT_OFFSET_BY_PARENT, input);
          continue;
        }
        else {
          cssDeclaration = CssDeclarationImpl.create(propertyName, CssRuleset.GUESS_TEXT_OFFSET_BY_PARENT);
          cssDeclarations[cssDeclarations.length] = cssDeclaration;
          propertyHolder = cssDeclaration;
          if ((flags & StyleFlags.EFFECT) != 0) {
            registerEffect(propertyName, object);
          }
          //noinspection AssignmentToFunctionParameterJS
          propertyName = "value";

          marker = input.readByte();
        }
      }

      switch (marker) {
        case AmfExtendedTypes.ID:
          propertyHolder.id = AmfUtil.readString(input);
          context.registerObjectWithId(propertyHolder.id, propertyHolder);
          // AS-272
          if (parent != null && parent.hasOwnProperty(propertyHolder.id)) {
            parent[propertyHolder.id] = propertyHolder;
          }
          continue;

        case AmfExtendedTypes.MX_CONTAINER_CHILDREN:
          readChildrenMxContainer(DisplayObjectContainer(propertyHolder));
          continue;

        case Amf3Types.STRING:
          propertyHolder[propertyName] = AmfUtil.readString(input);
          if (cssDeclaration != null) {
            cssDeclaration.type = Amf3Types.STRING;
          }
          break;

        case Amf3Types.OBJECT:
          propertyHolder[propertyName] = readMxmlObjectFromClass(stringRegistry.readNotNull(input));
          if (cssDeclaration != null) {
            cssDeclaration.type = CssPropertyType.EFFECT;
          }
          break;

        case AmfExtendedTypes.ARRAY_IF_LENGTH_GREATER_THAN_1:
          var ta:Array = readArray() as Array;
          if (ta.length > 0) {
            propertyHolder[propertyName] = ta.length == 1 ? ta[0] : ta;
          }
          break;

        case Amf3Types.VECTOR_OBJECT:
          propertyHolder[propertyName] = readVector();
          break;

        case AmfExtendedTypes.COLOR_STYLE:
          if (cssDeclaration == null) { 
            // todo property inspector
            propertyHolder[propertyName] = input.readObject();
          }
          else {
            cssDeclaration.type = input.readByte();
            if (cssDeclaration.type == CssPropertyType.COLOR_STRING) {
              cssDeclaration.colorName = stringRegistry.read(input);
            }
            cssDeclaration.value = input.readObject();
          }
          break;
        
        case AmfExtendedTypes.DOCUMENT_FACTORY_REFERENCE:
          propertyHolder[propertyName] = readDocumentFactory();
          break;

        case AmfExtendedTypes.IMAGE:
          propertyHolder[propertyName] = EmbedImageManager(module.project.getComponent(EmbedImageManager)).
                  get(AmfUtil.readUInt29(input), module.getClassPool(FlexLibrarySet.IMAGE_POOL), module.project);
          break;

        case AmfExtendedTypes.SWF:
          propertyHolder[propertyName] = EmbedSwfManager(module.project.getComponent(EmbedSwfManager)).get(AmfUtil.readUInt29(input),
                                                                                                           module.getClassPool(FlexLibrarySet.SWF_POOL),
                                                                                                           module.project);
          if (cssDeclaration != null) {
            cssDeclaration.type = CssPropertyType.EMBED;
          }
          break;

        case Amf3Types.DOUBLE:
        case Amf3Types.INTEGER:
          if (cssDeclaration != null) {
            cssDeclaration.type = CssPropertyType.NUMBER;
          }
          propertyHolder[propertyName] = readExpression(marker);
          break;

        case Amf3Types.TRUE:
        case Amf3Types.FALSE:
          if (cssDeclaration != null) {
            cssDeclaration.type = CssPropertyType.BOOL;
          }
          propertyHolder[propertyName] = readExpression(marker);
          break;

        default:
          propertyHolder[propertyName] = readExpression(marker, object, isStyle);
      }

      if (cssDeclaration != null) {
        cssDeclaration = null;
        propertyHolder = object;
      }
    }

    if (deferredSetStyleProxy != null) {
      if (deferredSetStyleProxy.inlineCssRuleset != null) {
        object.styleDeclaration = new module.inlineCssStyleDeclarationClass(deferredSetStyleProxy.inlineCssRuleset, module.styleManager.styleValueResolver);
        deferredSetStyleProxy.inlineCssRuleset = null;
      }
      deferredSetStyleProxyPool[deferredSetStyleProxyPool.length] = deferredSetStyleProxy;
      object.deferredSetStyles = null;
    }

    return object;
  }

  private function readXmlList():XMLList {
    const r:int = input.readUnsignedShort();
    var o:XMLList = new XMLList(AmfUtil.readString(input));
    processReference(r, o);
    return o;
  }

  private function readXml():XML {
    const r:int = input.readUnsignedShort();
    var o:XML = new XML(AmfUtil.readString(input));
    processReference(r, o);
    return o;
  }

  private function readReferable():Object {
    const r:int = input.readUnsignedShort();
    var o:Object = readExpression(input.readByte());
    processReference(r, o);
    return o;
  }

  private function processReference(reference:int, o:Object):void {
    if (reference != 0) {
      saveReferredObject(reference - 1, o);
    }
  }

  internal function saveReferredObject(id:int, o:Object):void {
    if (objectTable[id] != null) {
      throw new ArgumentError("must be null");
    }
    objectTable[id] = o;
  }

  private function readDocumentFactory():Object {
    const id:int = AmfUtil.readUInt29(input);
    var flexLibrarySet:FlexLibrarySet = module.flexLibrarySet;
    var factory:Object = flexLibrarySet.getDocumentFactory(id);
    if (factory == null) {
      var documentFactory:DocumentFactory = DocumentFactoryManager.getInstance().getById(id);
      factory = new flexLibrarySet.documentFactoryClass(documentFactory, new DeferredInstanceFromBytesContextImpl(documentFactory, styleManager));
      flexLibrarySet.putDocumentFactory(id, factory);
    }

    return factory;
  }

  private function readComponentFactory():Object {
    const id:int = AmfUtil.readUInt29(input);
    var data:ByteArray = new ByteArray();
    input.readBytes(data, 0, input.readUnsignedShort());
    var factory:Object = new (module.getClass("com.intellij.flex.uiDesigner.flex.FlexComponentFactory"))(data, getOrCreateFactoryContext());
    processReference(id, factory);
    return factory;
  }

  private function readProjectClassReference():Class {
    const id:int = AmfUtil.readUInt29(input);
    var classPool:ClassPool = module.getClassPool(FlexLibrarySet.VIEW_POOL);
    var clazz:Class = classPool.getCachedClass(id);
    if (clazz == null) {
      clazz = classPool.getClass(id);
      var documentFactory:DocumentFactory = DocumentFactoryManager.getInstance().getById(id);
      clazz["initializer"] = new (module.getClass("com.intellij.flex.uiDesigner.flex.SparkViewInitializer"))(documentFactory, new DeferredInstanceFromBytesContextImpl(documentFactory, styleManager));
    }

    return clazz;
  }

  private function getOrCreateFactoryContext():DeferredInstanceFromBytesContext {
    if (factoryContext == null) {
      factoryContext = new DeferredInstanceFromBytesContextImpl(context, styleManager);
    }
    
    return factoryContext;
  }

  protected function readChildrenMxContainer(container:DisplayObjectContainer):void {
  }

  internal function readArray(parent:Object = null):Object {
    const length:int = input.readUnsignedShort();
    return readArrayOrVector(new Array(length), length, parent);
  }

  internal function readMxmlArray():Object {
    const reference:int = input.readUnsignedShort();
    const length:int = input.readUnsignedShort();
    var o:Object = readArrayOrVector(new Array(length), length);
    processReference(reference, o);
    return o;
  }

  private function readVector():Object {
    var vectorClass:Class = module.getVectorClass(stringRegistry.readNotNull(input));
    const length:int = input.readUnsignedShort();
    return readArrayOrVector(new vectorClass(length), length);
  }

  private function readMxmlVector():Object {
    var vectorClass:Class = module.getVectorClass(stringRegistry.readNotNull(input));
    const fixed:Boolean = input.readBoolean();
    const reference:int = input.readUnsignedShort();
    const length:int = input.readUnsignedShort();
    var o:Object = readArrayOrVector(new vectorClass(length, fixed), length);
    processReference(reference, o);
    return o;
  }

  // support only object array without null
  internal function readArrayOrVector(array:Object, length:int, parent:Object = null):Object {
    var i:int = 0;
    var amfType:int;
    while (i < length) {
      amfType = input.readByte();
      if (amfType == Amf3Types.OBJECT) {
        array[i++] = readMxmlObjectFromClass(stringRegistry.readNotNull(input), parent);
      }
      else {
        array[i++] = readExpression(amfType);
        // see http://confluence.jetbrains.net/display/IDEA/Flex+UI+Designer MXMLWriter
        if (length == 1 && amfType == AmfExtendedTypes.MXML_ARRAY && array is Array) {
          return array[0];
        }
      }
    }

    return array;
  }

  internal function readClassOrPropertyName():String {
    return stringRegistry.read(input);
  }

  public static function readPrimitive(amfType:int, input:IDataInput, stringRegistry:StringRegistry):Object {
    switch (amfType) {
      case Amf3Types.STRING:
        return AmfUtil.readString(input);

      case AmfExtendedTypes.STRING_REFERENCE:
        return stringRegistry.read(input);

      case Amf3Types.INTEGER:
        return (AmfUtil.readUInt29(input) << 3) >> 3;

      case Amf3Types.DOUBLE:
        return input.readDouble();

      case Amf3Types.FALSE:
        return false;

      case Amf3Types.TRUE:
        return true;

      case Amf3Types.NULL:
        return null;

      case AmfExtendedTypes.COLOR_STYLE:
        return input.readObject();
    }

    return input;
  }

  internal function readExpression(amfType:int, target:Object = null, isStyle:Boolean = false):* {
    var v:Object;
    if ((v = readPrimitive(amfType, input, stringRegistry)) != input) {
      return v;
    }

    switch (amfType) {
      case Amf3Types.OBJECT:
        return readMxmlObjectFromClass(stringRegistry.readNotNull(input), target);

      case ExpressionMessageTypes.SIMPLE_OBJECT:
        return readSimpleObject(new Object());

      case Amf3Types.ARRAY:
        return readArray(target);

      case ExpressionMessageTypes.CALL:
        return callFunction(target, isStyle);

      case ExpressionMessageTypes.NEW:
        return constructObject();

      case AmfExtendedTypes.MXML_ARRAY:
        return readMxmlArray();

      case AmfExtendedTypes.MXML_VECTOR:
        return readMxmlVector();

      case ExpressionMessageTypes.MXML_OBJECT_REFERENCE:
        return injectedASReader.readMxmlObjectReference(input, this);

      case AmfExtendedTypes.OBJECT_REFERENCE:
        return readObjectReference();

      case AmfExtendedTypes.DOCUMENT_REFERENCE:
        return readObjectProperties(readDocumentFactory().newInstance(), target);

      case AmfExtendedTypes.COMPONENT_FACTORY:
        return readComponentFactory();

      case ExpressionMessageTypes.VARIABLE_REFERENCE:
        return injectedASReader.readVariableReference(input);

      case AmfExtendedTypes.REFERABLE:
        return readReferable();

      case AmfExtendedTypes.XML_LIST:
        return readXmlList();

      case AmfExtendedTypes.XML:
        return readXml();

      case AmfExtendedTypes.OBJECT:
        return readSimpleObject(new (module.getClass(stringRegistry.readNotNull(input)))());

      case AmfExtendedTypes.CLASS_REFERENCE:
        return module.applicationDomain.getDefinition(stringRegistry.readNotNull(input));

      case AmfExtendedTypes.TRANSIENT_ARRAY_OF_DEFERRED_INSTANCE_FROM_BYTES:
        return new (module.getClass("com.intellij.flex.uiDesigner.flex.states.TransientArrayOfDeferredInstanceFromBytes"))(stateReader.readVectorOfDeferredInstanceFromBytes(this, input), getOrCreateFactoryContext());

      case AmfExtendedTypes.PERMANENT_ARRAY_OF_DEFERRED_INSTANCE_FROM_BYTES:
        return new (module.getClass("com.intellij.flex.uiDesigner.flex.states.PermanentArrayOfDeferredInstanceFromBytes"))(stateReader.readArrayOfDeferredInstanceFromBytes(this, input), getOrCreateFactoryContext());

      case AmfExtendedTypes.PROJECT_CLASS_REFERENCE:
        return readProjectClassReference();

      case AmfExtendedTypes.SWF:
        var assetClass:Class = EmbedSwfManager(module.project.getComponent(EmbedSwfManager)).get(AmfUtil.readUInt29(input),
                                                                                                 module.getClassPool(FlexLibrarySet.SWF_POOL),
                                                                                                 module.project);
        var wrapper:Object = new (module.getClass("spark.core.SpriteVisualElement"));
        wrapper.addChild(new assetClass());
        return wrapper;

      default:
        throw new ArgumentError("unknown property type " + amfType);
    }    
  }

  private function callFunction(target:Object, isStyle:Boolean):* {
    assert(target != null);

    const dataLength:int = input.readUnsignedShort();
    const start:int = input.bytesAvailable;
    try {
      var qualifier:Object = rootObject;
      var qualifierName:String;
      while ((qualifierName = stringRegistry.read(input)) != null) {
        // resourceManager is protected
        if (qualifierName == "resourceManager" && !(qualifierName in qualifier)) {
          qualifier = module.getClass("mx.resources.ResourceManager")["getInstance"]();
        }
        else {
          qualifier = qualifier[qualifierName];
        }
      }

      const functionName:String = stringRegistry.readNotNull(input);
      const argumentsLength:int = input.readByte();
      // isGetter
      if (argumentsLength < 0) {
        if (argumentsLength == -2) {
          injectedASReader.initChangeWatcher(target, functionName, isStyle, null, qualifier);
        }

        return qualifier[functionName];
      }
      else if (argumentsLength == 0) {
        return qualifier[functionName]();
      }
      else {
        return (qualifier[functionName] as Function).apply(null, readArrayOrVector(new Array(argumentsLength), argumentsLength));
      }
    }
    catch (e:Error) {
      handleCallExpressionBindingError(e, dataLength, start);
    }

    return null;
  }

  private function constructObject():Object {
    var clazz:Class = module.getClass(stringRegistry.readNotNull(input));
    var argumentsLength:int = input.readByte();

    var dataLength:int;
    var start:int;
    if ((argumentsLength & 1) != 0) {
      dataLength = input.readUnsignedShort();
      start = input.bytesAvailable;
    }

    argumentsLength >>= 1;

    try {
      if (argumentsLength == 0) {
        return new clazz();
      }
      else {
        switch (argumentsLength) {
          case 1:
            return new clazz(readExpression(input.readByte()));
          case 2:
            return new clazz(readExpression(input.readByte()), readExpression(input.readByte()));
          case 3:
            return new clazz(readExpression(input.readByte()), readExpression(input.readByte()), readExpression(input.readByte()));
          case 4:
            return new clazz(readExpression(input.readByte()), readExpression(input.readByte()), readExpression(input.readByte()), readExpression(input.readByte()));
          case 5:
            return new clazz(readExpression(input.readByte()), readExpression(input.readByte()), readExpression(input.readByte()), readExpression(input.readByte()), readExpression(input.readByte()));
          case 6:
            return new clazz(readExpression(input.readByte()), readExpression(input.readByte()), readExpression(input.readByte()), readExpression(input.readByte()), readExpression(input.readByte()), readExpression(input.readByte()));
          case 7:
            return new clazz(readExpression(input.readByte()), readExpression(input.readByte()), readExpression(input.readByte()), readExpression(input.readByte()), readExpression(input.readByte()), readExpression(input.readByte()),
                             readExpression(input.readByte()));
          case 8:
            return new clazz(readExpression(input.readByte()), readExpression(input.readByte()), readExpression(input.readByte()), readExpression(input.readByte()), readExpression(input.readByte()), readExpression(input.readByte()),
                             readExpression(input.readByte()), readExpression(input.readByte()));
          case 9:
            return new clazz(readExpression(input.readByte()), readExpression(input.readByte()), readExpression(input.readByte()), readExpression(input.readByte()), readExpression(input.readByte()), readExpression(input.readByte()),
                             readExpression(input.readByte()), readExpression(input.readByte()), readExpression(input.readByte()));
          case 10:
            return new clazz(readExpression(input.readByte()), readExpression(input.readByte()), readExpression(input.readByte()), readExpression(input.readByte()), readExpression(input.readByte()), readExpression(input.readByte()),
                             readExpression(input.readByte()), readExpression(input.readByte()), readExpression(input.readByte()), readExpression(input.readByte()));
        }

        UncaughtErrorManager.instance.logWarning("Can't execute binding, constructorArguments is too long");
      }
    }
    catch (e:Error) {
      if (dataLength == 0) {
        throw e;
      }
      else {
        handleCallExpressionBindingError(e, dataLength, start);
      }
    }

    return null;
  }

  private function handleCallExpressionBindingError(e:Error, dataLength:int, start:int):void {
    UncaughtErrorManager.instance.logWarning3("Can't execute binding", e);

    var unreadLength:int = dataLength - (start - input.bytesAvailable);
    if (unreadLength > 0) {
      input.readBytes(new ByteArray(), 0, unreadLength);
    }
  }
  
  internal function readSimpleObject(o:Object):Object {
    var propertyName:String;
    while ((propertyName = stringRegistry.read(input)) != null) {
      if (propertyName == "2") {
        saveReferredObject(AmfUtil.readUInt29(input), o);
      }
      else {
        o[propertyName] = readExpression(input.readByte());
      }
    }
    
    return o;
  }
}
}

import flash.utils.Proxy;
import flash.utils.flash_proxy;

use namespace flash_proxy;

// IDEA-72366
final class DeferredSetStyleProxy extends Proxy {
  internal var file:VirtualFile;
  internal var inlineCssRuleset:CssRuleset;
  internal var objectDeclarationTextOffset:int;

  override flash_proxy function setProperty(name:*, value:*):void {
    if (inlineCssRuleset == null) {
      inlineCssRuleset = InlineCssRuleset.createInline(0, objectDeclarationTextOffset, file);
    }

    var cssDeclaration:CssDeclarationImpl = CssDeclarationImpl.create(name, CssRuleset.GUESS_TEXT_OFFSET_BY_PARENT);
    cssDeclaration.value = value;
    inlineCssRuleset.declarations.push(cssDeclaration);
  }

  override flash_proxy function getProperty(name:*):* {
    if (inlineCssRuleset == null) {
      return undefined;
    }
    else {
      var declaration:* = inlineCssRuleset.declarationMap[name];
      return declaration === undefined ? undefined : CssDeclaration(declaration).value;
    }
  }
}