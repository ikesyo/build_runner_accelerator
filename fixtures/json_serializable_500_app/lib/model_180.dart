import 'package:json_annotation/json_annotation.dart';

part 'model_180.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model180 {
  const Model180({required this.id, required this.value});

  final int id;
  final String value;

  factory Model180.fromJson(Map<String, dynamic> json) =>
      _$Model180FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model180ToJson(this);
}
