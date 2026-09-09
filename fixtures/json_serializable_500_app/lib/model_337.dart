import 'package:json_annotation/json_annotation.dart';

part 'model_337.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model337 {
  const Model337({required this.id, required this.value});

  final int id;
  final String value;

  factory Model337.fromJson(Map<String, dynamic> json) =>
      _$Model337FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model337ToJson(this);
}
