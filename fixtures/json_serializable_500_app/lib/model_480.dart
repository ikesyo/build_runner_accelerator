import 'package:json_annotation/json_annotation.dart';

part 'model_480.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model480 {
  const Model480({required this.id, required this.value});

  final int id;
  final String value;

  factory Model480.fromJson(Map<String, dynamic> json) =>
      _$Model480FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model480ToJson(this);
}
