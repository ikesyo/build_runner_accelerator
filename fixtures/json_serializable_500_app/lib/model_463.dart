import 'package:json_annotation/json_annotation.dart';

part 'model_463.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model463 {
  const Model463({required this.id, required this.value});

  final int id;
  final String value;

  factory Model463.fromJson(Map<String, dynamic> json) =>
      _$Model463FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model463ToJson(this);
}
