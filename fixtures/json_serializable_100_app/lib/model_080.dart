import 'package:json_annotation/json_annotation.dart';

part 'model_080.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model080 {
  const Model080({required this.id, required this.value});

  final int id;
  final String value;

  factory Model080.fromJson(Map<String, dynamic> json) =>
      _$Model080FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model080ToJson(this);
}
