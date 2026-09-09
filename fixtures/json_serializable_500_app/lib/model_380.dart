import 'package:json_annotation/json_annotation.dart';

part 'model_380.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model380 {
  const Model380({required this.id, required this.value});

  final int id;
  final String value;

  factory Model380.fromJson(Map<String, dynamic> json) =>
      _$Model380FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model380ToJson(this);
}
