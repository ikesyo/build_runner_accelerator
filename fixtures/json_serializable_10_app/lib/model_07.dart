import 'package:json_annotation/json_annotation.dart';

part 'model_07.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model07 {
  const Model07({required this.id, required this.value});

  final int id;
  final String value;

  factory Model07.fromJson(Map<String, dynamic> json) =>
      _$Model07FromJson(json);

  Map<String, dynamic> toJson() => _$Model07ToJson(this);
}
