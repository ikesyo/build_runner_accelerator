import 'package:json_annotation/json_annotation.dart';

part 'model_054.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model054 {
  const Model054({required this.id, required this.value});

  final int id;
  final String value;

  factory Model054.fromJson(Map<String, dynamic> json) =>
      _$Model054FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model054ToJson(this);
}
