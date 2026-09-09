import 'package:json_annotation/json_annotation.dart';

part 'model_334.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model334 {
  const Model334({required this.id, required this.value});

  final int id;
  final String value;

  factory Model334.fromJson(Map<String, dynamic> json) =>
      _$Model334FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model334ToJson(this);
}
