import 'package:built_value/built_value.dart';

part 'model.g.dart';

abstract class Model implements Built<Model, ModelBuilder> {
  static Serializer<Model> get serializer => _$modelSerializer;

  String get value;

  factory Model([void Function(ModelBuilder) updates]) = _$Model;

  Model._();
}
